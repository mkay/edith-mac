// SPDX-FileCopyrightText: 2025 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Edith ↔ Monaco bridge
// Communicates with Python via window.webkit.messageHandlers.edith.postMessage()
(function () {
  "use strict";

  var editor = null;
  var monacoRef = null;
  var cleanVersionId = null;
  var lastModifiedState = false;
  var pendingCalls = [];
  var ready = false;
  var loadingContent = false;  // suppress dirty tracking during setValue
  var snapshotTimer = null;    // debounced content snapshot for crash recovery

  // Report to Python whenever the model's undo history is thrown away, so a
  // lost undo stack shows up in the log instead of being a mystery.
  function reportHistoryReset(reason) {
    postMessage("history-reset", { reason: reason });
  }

  // Replace the whole buffer *without* destroying undo history.
  // editor.setValue() resets the model's EditStack; pushEditOperations keeps
  // it and makes the replacement itself undoable.
  function replaceContentPreservingHistory(content) {
    var model = editor.getModel();
    if (model.getValue() === content) return false;

    var selections = editor.getSelections();
    var scrollTop = editor.getScrollTop();
    var scrollLeft = editor.getScrollLeft();

    loadingContent = true;
    try {
      model.pushStackElement();
      model.pushEditOperations(
        selections,
        [{ range: model.getFullModelRange(), text: content }],
        function () { return null; }
      );
      model.pushStackElement();
    } finally {
      loadingContent = false;
    }

    // Restore cursor/selection, clamped to the new content bounds.
    if (selections && selections.length) {
      try {
        editor.setSelections(selections.map(function (s) {
          return model.validateRange(s);
        }));
      } catch (e) {}
    }
    editor.setScrollTop(scrollTop);
    editor.setScrollLeft(scrollLeft);
    return true;
  }

  // ── Custom options splitter ───────────────────────────────────────────
  // User-provided overrides may mix Monaco editor options with language
  // service options (HTML/CSS/JSON formatter settings). The editor options
  // go to editor.updateOptions(); the service options go to the relevant
  // language defaults. Accepts two forms:
  //   flat dotted keys:   "html.format.wrapLineLength": 0
  //   nested objects:     { "html": { "format": { "wrapLineLength": 0 } } }
  var SERVICE_DEFAULTS = {
    html:  ["languages", "html", "htmlDefaults"],
    css:   ["languages", "css",  "cssDefaults"],
    scss:  ["languages", "css",  "scssDefaults"],
    less:  ["languages", "css",  "lessDefaults"],
    json:  ["languages", "json", "jsonDefaults"],
  };
  function resolveDefaults(name) {
    if (!monacoRef) return null;
    var path = SERVICE_DEFAULTS[name];
    if (!path) return null;
    var node = monacoRef;
    for (var i = 0; i < path.length; i++) {
      node = node && node[path[i]];
      if (!node) return null;
    }
    return node;
  }
  function splitCustomOptions(customOptions) {
    var editorOpts = {};
    var serviceOpts = {};  // { html: { format: {...} }, ... }
    function stash(lang, section, key, val) {
      if (!serviceOpts[lang]) serviceOpts[lang] = {};
      if (section) {
        if (!serviceOpts[lang][section]) serviceOpts[lang][section] = {};
        serviceOpts[lang][section][key] = val;
      } else {
        serviceOpts[lang][key] = val;
      }
    }
    for (var key in customOptions) {
      if (!Object.prototype.hasOwnProperty.call(customOptions, key)) continue;
      var val = customOptions[key];
      var dotted = key.match(/^([a-z]+)\.([a-z]+)\.(.+)$/i);
      if (dotted && SERVICE_DEFAULTS[dotted[1]]) {
        stash(dotted[1], dotted[2], dotted[3], val);
        continue;
      }
      if (SERVICE_DEFAULTS[key] && val && typeof val === "object") {
        for (var section in val) {
          if (!Object.prototype.hasOwnProperty.call(val, section)) continue;
          var sv = val[section];
          if (sv && typeof sv === "object") {
            for (var sk in sv) {
              if (Object.prototype.hasOwnProperty.call(sv, sk)) stash(key, section, sk, sv[sk]);
            }
          } else {
            stash(key, null, section, sv);
          }
        }
        continue;
      }
      editorOpts[key] = val;
    }
    return { editor: editorOpts, services: serviceOpts };
  }
  function applyServiceOptions(serviceOpts) {
    for (var lang in serviceOpts) {
      if (!Object.prototype.hasOwnProperty.call(serviceOpts, lang)) continue;
      var defaults = resolveDefaults(lang);
      if (!defaults || typeof defaults.setOptions !== "function") continue;
      var incoming = serviceOpts[lang];
      var existing = (defaults.options && typeof defaults.options === "object") ? defaults.options : {};
      var merged = {};
      for (var k in existing) if (Object.prototype.hasOwnProperty.call(existing, k)) merged[k] = existing[k];
      for (var k2 in incoming) {
        if (!Object.prototype.hasOwnProperty.call(incoming, k2)) continue;
        var iv = incoming[k2];
        var ev = existing[k2];
        if (iv && typeof iv === "object" && ev && typeof ev === "object") {
          var sub = {};
          for (var ek in ev) if (Object.prototype.hasOwnProperty.call(ev, ek)) sub[ek] = ev[ek];
          for (var ik in iv) if (Object.prototype.hasOwnProperty.call(iv, ik)) sub[ik] = iv[ik];
          merged[k2] = sub;
        } else {
          merged[k2] = iv;
        }
      }
      try {
        defaults.setOptions(merged);
      } catch (e) {
        console.warn("Edith: failed to apply " + lang + " language options:", e);
      }
    }
  }

  // ── Post a message to Python ──────────────────────────────────────────
  function postMessage(type, data) {
    try {
      window.webkit.messageHandlers.edith.postMessage(
        JSON.stringify({ type: type, data: data || {} })
      );
    } catch (e) {
      // messageHandler may not be registered yet
    }
  }

  // ── Custom theme definitions ──────────────────────────────────────────
  function defineCustomThemes(monaco) {
    monaco.editor.defineTheme("monokai", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "comment", foreground: "75715E", fontStyle: "italic" },
        { token: "keyword", foreground: "F92672" },
        { token: "string", foreground: "E6DB74" },
        { token: "number", foreground: "AE81FF" },
        { token: "type", foreground: "66D9EF", fontStyle: "italic" },
        { token: "function", foreground: "A6E22E" },
        { token: "variable", foreground: "F8F8F2" },
        { token: "constant", foreground: "AE81FF" },
        { token: "tag", foreground: "F92672" },
        { token: "attribute.name", foreground: "A6E22E" },
        { token: "attribute.value", foreground: "E6DB74" },
        { token: "delimiter", foreground: "F8F8F2" },
      ],
      colors: {
        "editor.background": "#272822",
        "editor.foreground": "#F8F8F2",
        "editor.lineHighlightBackground": "#3E3D32",
        "editor.selectionBackground": "#49483E",
        "editorCursor.foreground": "#F8F8F0",
        "editorLineNumber.foreground": "#90908A",
      },
    });

    monaco.editor.defineTheme("one-dark", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "comment", foreground: "5C6370", fontStyle: "italic" },
        { token: "keyword", foreground: "C678DD" },
        { token: "string", foreground: "98C379" },
        { token: "number", foreground: "D19A66" },
        { token: "type", foreground: "E5C07B" },
        { token: "function", foreground: "61AFEF" },
        { token: "variable", foreground: "E06C75" },
        { token: "tag", foreground: "E06C75" },
        { token: "attribute.name", foreground: "D19A66" },
        { token: "attribute.value", foreground: "98C379" },
      ],
      colors: {
        "editor.background": "#282C34",
        "editor.foreground": "#ABB2BF",
        "editor.lineHighlightBackground": "#2C313C",
        "editor.selectionBackground": "#3E4451",
        "editorCursor.foreground": "#528BFF",
        "editorLineNumber.foreground": "#636D83",
      },
    });

    monaco.editor.defineTheme("dracula", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "comment", foreground: "6272A4", fontStyle: "italic" },
        { token: "keyword", foreground: "FF79C6" },
        { token: "string", foreground: "F1FA8C" },
        { token: "number", foreground: "BD93F9" },
        { token: "type", foreground: "8BE9FD", fontStyle: "italic" },
        { token: "function", foreground: "50FA7B" },
        { token: "variable", foreground: "F8F8F2" },
        { token: "tag", foreground: "FF79C6" },
        { token: "attribute.name", foreground: "50FA7B" },
        { token: "attribute.value", foreground: "F1FA8C" },
      ],
      colors: {
        "editor.background": "#282A36",
        "editor.foreground": "#F8F8F2",
        "editor.lineHighlightBackground": "#44475A",
        "editor.selectionBackground": "#44475A",
        "editorCursor.foreground": "#F8F8F0",
        "editorLineNumber.foreground": "#6272A4",
      },
    });

    monaco.editor.defineTheme("solarized-dark", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "comment", foreground: "586E75", fontStyle: "italic" },
        { token: "keyword", foreground: "859900" },
        { token: "string", foreground: "2AA198" },
        { token: "number", foreground: "D33682" },
        { token: "type", foreground: "B58900" },
        { token: "function", foreground: "268BD2" },
        { token: "variable", foreground: "839496" },
      ],
      colors: {
        "editor.background": "#002B36",
        "editor.foreground": "#839496",
        "editor.lineHighlightBackground": "#073642",
        "editor.selectionBackground": "#073642",
        "editorCursor.foreground": "#839496",
        "editorLineNumber.foreground": "#586E75",
      },
    });

    monaco.editor.defineTheme("solarized-light", {
      base: "vs",
      inherit: true,
      rules: [
        { token: "comment", foreground: "93A1A1", fontStyle: "italic" },
        { token: "keyword", foreground: "859900" },
        { token: "string", foreground: "2AA198" },
        { token: "number", foreground: "D33682" },
        { token: "type", foreground: "B58900" },
        { token: "function", foreground: "268BD2" },
        { token: "variable", foreground: "657B83" },
      ],
      colors: {
        "editor.background": "#FDF6E3",
        "editor.foreground": "#657B83",
        "editor.lineHighlightBackground": "#EEE8D5",
        "editor.selectionBackground": "#EEE8D5",
        "editorCursor.foreground": "#657B83",
        "editorLineNumber.foreground": "#93A1A1",
      },
    });

    monaco.editor.defineTheme("nord", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "comment", foreground: "616E88", fontStyle: "italic" },
        { token: "keyword", foreground: "81A1C1" },
        { token: "string", foreground: "A3BE8C" },
        { token: "number", foreground: "B48EAD" },
        { token: "type", foreground: "8FBCBB" },
        { token: "function", foreground: "88C0D0" },
        { token: "variable", foreground: "D8DEE9" },
      ],
      colors: {
        "editor.background": "#2E3440",
        "editor.foreground": "#D8DEE9",
        "editor.lineHighlightBackground": "#3B4252",
        "editor.selectionBackground": "#434C5E",
        "editorCursor.foreground": "#D8DEE9",
        "editorLineNumber.foreground": "#4C566A",
      },
    });

    monaco.editor.defineTheme("github-light", {
      base: "vs",
      inherit: true,
      rules: [
        { token: "comment", foreground: "6A737D", fontStyle: "italic" },
        { token: "keyword", foreground: "D73A49" },
        { token: "string", foreground: "032F62" },
        { token: "number", foreground: "005CC5" },
        { token: "type", foreground: "6F42C1" },
        { token: "function", foreground: "6F42C1" },
        { token: "variable", foreground: "24292E" },
      ],
      colors: {
        "editor.background": "#FFFFFF",
        "editor.foreground": "#24292E",
        "editor.lineHighlightBackground": "#F6F8FA",
        "editor.selectionBackground": "#C8C8FA",
        "editorCursor.foreground": "#24292E",
        "editorLineNumber.foreground": "#959DA5",
      },
    });

    monaco.editor.defineTheme("github-dark", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "comment", foreground: "8B949E", fontStyle: "italic" },
        { token: "keyword", foreground: "FF7B72" },
        { token: "string", foreground: "A5D6FF" },
        { token: "number", foreground: "79C0FF" },
        { token: "type", foreground: "D2A8FF" },
        { token: "function", foreground: "D2A8FF" },
        { token: "variable", foreground: "C9D1D9" },
      ],
      colors: {
        "editor.background": "#0D1117",
        "editor.foreground": "#C9D1D9",
        "editor.lineHighlightBackground": "#161B22",
        "editor.selectionBackground": "#264F78",
        "editorCursor.foreground": "#C9D1D9",
        "editorLineNumber.foreground": "#484F58",
      },
    });
  }

  // ── Worker setup ────────────────────────────────────────────────────────
  // workerMain.js bundles an AMD loader + base worker.  Its module loader
  // tries fetch()+eval() for same-origin URLs, but WebKitGTK does not
  // support fetch() for file:// URLs inside workers.  We create a blob
  // worker that patches fetch() to use synchronous XMLHttpRequest (which
  // works in workers for file:// URLs), then loads workerMain.js.
  var monacoBaseUrl = location.href.replace(/\/[^/]*$/, "/");
  window.MonacoEnvironment = {
    getWorker: function () {
      var blob = new Blob([
        // Patch fetch() so the AMD loader can load file:// modules
        'var _origFetch = self.fetch;\n' +
        'self.fetch = function(url, opts) {\n' +
        '  if (typeof url === "string" && url.indexOf("file:") === 0) {\n' +
        '    return new Promise(function(resolve, reject) {\n' +
        '      try {\n' +
        '        var xhr = new XMLHttpRequest();\n' +
        '        xhr.open("GET", url, false);\n' +
        '        xhr.send();\n' +
        '        resolve({ ok: true, status: 200, text: function() { return Promise.resolve(xhr.responseText); } });\n' +
        '      } catch(e) { reject(e); }\n' +
        '    });\n' +
        '  }\n' +
        '  return _origFetch.apply(self, arguments);\n' +
        '};\n' +
        'self.MonacoEnvironment = { baseUrl: "' + monacoBaseUrl + '" };\n' +
        'importScripts("' + monacoBaseUrl + 'vs/base/worker/workerMain.js");'
      ], { type: "application/javascript" });
      return new Worker(URL.createObjectURL(blob));
    },
  };

  // ── AMD loader config & editor creation ───────────────────────────────
  // An absolute baseUrl is required so that the AMD config Monaco
  // serialises into Web Workers resolves modules correctly. The vs path
  // stays relative to it: the loader only treats http(s):, file: and /
  // as absolute, so an absolute edith:// path would get baseUrl prefixed
  // a second time.
  require.config({ baseUrl: monacoBaseUrl, paths: { vs: "vs" } });

  require(["vs/editor/editor.main"], function (monaco) {
    monacoRef = monaco;
    defineCustomThemes(monaco);

    editor = monaco.editor.create(document.getElementById("editor"), {
      value: "",
      language: "plaintext",
      theme: "vs-dark",
      automaticLayout: true,
      fontSize: 14,
      fontFamily: "'Monospace', monospace",
      minimap: { enabled: false },
      lineNumbers: "on",
      wordWrap: "on",
      scrollBeyondLastLine: false,
      renderWhitespace: "selection",
      tabSize: 4,
      insertSpaces: true,
      bracketPairColorization: { enabled: true },
      smoothScrolling: true,
      cursorBlinking: "smooth",
      tabCompletion: "on",
    });

    cleanVersionId = editor.getModel().getAlternativeVersionId();
    lastModifiedState = false;

    // ── Emmet ───────────────────────────────────────────────────────── //
    if (window.emmetMonaco) {
      try {
        emmetMonaco.emmetHTML(monaco, [
          "html", "php", "twig", "blade", "handlebars", "liquid",
          "javascript", "typescript", "jsx", "tsx",
        ]);
        emmetMonaco.emmetCSS(monaco, ["css", "less", "scss"]);
      } catch (e) {
        console.warn("Emmet init failed:", e);
      }
    }

    // Tab expands Emmet abbreviations directly (no dropdown needed).
    // Only fires when there is no selection and no suggest widget visible,
    // so normal Tab indentation still works on selected text.
    editor.addCommand(
      monaco.KeyCode.Tab,
      function () {
        if (window.emmetMonaco) {
          var model = editor.getModel();
          var position = editor.getPosition();
          var langId = model.getLanguageId();

          // Extract the abbreviation: everything after the last whitespace
          // before the cursor (Emmet abbrs never contain spaces).
          var lineText = model.getLineContent(position.lineNumber);
          var textBefore = lineText.substring(0, position.column - 1);
          var abbrMatch = textBefore.match(/[^\s<>"'=]+$/);

          if (abbrMatch) {
            var abbr = abbrMatch[0];
            var cssLangs = ["css", "less", "scss", "sass", "stylus"];
            var type = cssLangs.indexOf(langId) !== -1 ? "stylesheet" : "markup";

            // output.field produces VS Code/Monaco snippet tabstop syntax
            var snipField = function (index, placeholder) {
              return "${" + index + (placeholder ? ":" + placeholder : "") + "}";
            };

            try {
              var expanded = emmetMonaco.expandAbbreviation(abbr, {
                type: type,
                syntax: langId || "html",
                options: { "output.field": snipField },
              });

              // Only apply if the expansion is meaningfully different from input
              if (expanded && expanded !== abbr) {
                var snippetCtrl = editor.getContribution("snippetController2");
                if (snippetCtrl) {
                  snippetCtrl.insert(expanded, { overwriteBefore: abbr.length });
                  return;
                }
              }
            } catch (e) {}
          }
        }

        // No Emmet expansion — insert tab/spaces normally
        var opts = editor.getModel().getOptions();
        editor.trigger("keyboard", "type", {
          text: opts.insertSpaces ? " ".repeat(opts.tabSize) : "\t",
        });
      },
      "editorTextFocus && !editorHasSelection && !suggestWidgetVisible"
    );

    // Report cursor position changes to Python (debounced to reduce IPC chatter)
    var cursorTimer = null;
    editor.onDidChangeCursorPosition(function (e) {
      if (cursorTimer) clearTimeout(cursorTimer);
      cursorTimer = setTimeout(function () {
        cursorTimer = null;
        postMessage("cursor-changed", {
          line: e.position.lineNumber,
          column: e.position.column,
        });
      }, 16);
    });

    // Track modification state
    editor.getModel().onDidChangeContent(function () {
      if (loadingContent) return;
      var currentVersionId = editor.getModel().getAlternativeVersionId();
      var isModified = currentVersionId !== cleanVersionId;
      if (isModified !== lastModifiedState) {
        lastModifiedState = isModified;
        postMessage("modified-changed", { modified: isModified });
      }
      // Keep Python holding a recent copy of unsaved text: if the WebKit
      // render process dies, the tab is rebuilt from this instead of from
      // the (stale) file on disk.  Debounced to keep IPC traffic sane.
      if (isModified) {
        if (snapshotTimer) clearTimeout(snapshotTimer);
        snapshotTimer = setTimeout(function () {
          snapshotTimer = null;
          postMessage("content-snapshot", { content: editor.getValue() });
        }, 2000);
      }
    });

    // Ctrl+S → save-requested
    editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS,
      function () {
        postMessage("save-requested", {});
      }
    );

    // Ctrl+W → close-requested
    editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyW,
      function () {
        postMessage("close-requested", {});
      }
    );

    // Flush any calls that arrived before ready
    ready = true;
    for (var i = 0; i < pendingCalls.length; i++) {
      pendingCalls[i]();
    }
    pendingCalls = [];

    postMessage("ready", {});
  });

  // ── EdithBridge: API called from Python via evaluate_javascript ──────
  window.EdithBridge = {
    // init(content, language, theme, fontFamily, fontSize, wordWrap, settings, customOptions)
    // settings: { insertSpaces, tabSize, minimap, renderWhitespace,
    //             stickyScroll, fontLigatures, lineNumbers }
    // customOptions: arbitrary Monaco editor options from user config
    init: function (content, language, theme, fontFamily, fontSize, wordWrap, settings, customOptions) {
      function run() {
        if (content != null) {
          // Only the initial load may use setValue (fresh model, no history
          // worth keeping).  Everything else goes through setContent.
          loadingContent = true;
          editor.setValue(content);
          loadingContent = false;
          reportHistoryReset("init");
          cleanVersionId = editor.getModel().getAlternativeVersionId();
          lastModifiedState = false;
        }
        if (language) {
          monaco.editor.setModelLanguage(editor.getModel(), language);
        }
        if (theme) {
          monaco.editor.setTheme(theme);
        }
        // Batch all options into a single updateOptions call
        var opts = {};
        if (fontFamily) opts.fontFamily = fontFamily;
        if (fontSize) opts.fontSize = fontSize;
        if (wordWrap !== undefined) opts.wordWrap = wordWrap ? "on" : "off";
        if (settings) {
          var s = settings;
          if (s.insertSpaces !== undefined) {
            opts.insertSpaces = s.insertSpaces;
            opts.tabSize = s.tabSize || 4;
            editor.getModel().updateOptions({ insertSpaces: s.insertSpaces, tabSize: s.tabSize || 4 });
          }
          if (s.minimap !== undefined) opts.minimap = { enabled: s.minimap };
          if (s.renderWhitespace) opts.renderWhitespace = s.renderWhitespace;
          if (s.stickyScroll !== undefined) opts.stickyScroll = { enabled: s.stickyScroll };
          if (s.fontLigatures !== undefined) opts.fontLigatures = s.fontLigatures;
          if (s.lineNumbers) opts.lineNumbers = s.lineNumbers;
        }
        // Merge user custom overrides (raw Monaco options) on top.
        // Split off language-service options (html/css/json format, etc.)
        // which must be set on the language defaults rather than the editor.
        if (customOptions && typeof customOptions === "object") {
          var split = splitCustomOptions(customOptions);
          for (var key in split.editor) {
            if (Object.prototype.hasOwnProperty.call(split.editor, key)) opts[key] = split.editor[key];
          }
          applyServiceOptions(split.services);
        }
        editor.updateOptions(opts);
        // Report detected line ending to Python
        postMessage("init-complete", {
          lineEnding: editor.getModel().getEOL() === "\r\n" ? "crlf" : "lf",
          wordWrap: editor.getOption(monaco.editor.EditorOption.wordWrap) === "on",
        });
      }
      if (ready) run();
      else pendingCalls.push(run);
    },

    // Reload content from disk.  Never uses setValue(): the undo stack must
    // survive a remote-change reload, and an unchanged file must be a no-op.
    setContent: function (content) {
      if (!editor) return;
      replaceContentPreservingHistory(content);
      cleanVersionId = editor.getModel().getAlternativeVersionId();
      if (lastModifiedState) {
        lastModifiedState = false;
        postMessage("modified-changed", { modified: false });
      }
    },

    // Undo/redo driven from the GTK window accelerators.
    //
    // editor.trigger("keyboard", "undo") is *not* reliable here: "undo" is not
    // an editor action, so it falls through to the command service, whose
    // implementation resolves via ICodeEditorService.getFocusedCodeEditor().
    // If the WebView doesn't hold DOM focus the command silently does nothing.
    // Focus first, then fall back to the model's own edit stack if the
    // version id didn't move.
    undo: function () {
      if (!editor) return;
      var model = editor.getModel();
      var before = model.getAlternativeVersionId();
      editor.focus();
      editor.trigger("keyboard", "undo");
      if (model.getAlternativeVersionId() === before && model.undo) {
        model.undo();
      }
    },

    redo: function () {
      if (!editor) return;
      var model = editor.getModel();
      var before = model.getAlternativeVersionId();
      editor.focus();
      editor.trigger("keyboard", "redo");
      if (model.getAlternativeVersionId() === before && model.redo) {
        model.redo();
      }
    },

    getContent: function () {
      if (!editor) return "";
      return editor.getValue();
    },

    // Prepare content for saving (optionally format first), then send
    // it back to Python via the "save-content" postMessage.
    savePrepare: function (doFormat) {
      if (!editor) {
        postMessage("save-content", { content: "" });
        return;
      }
      var send = function () {
        postMessage("save-content", { content: editor.getValue() });
      };
      if (doFormat) {
        var action = editor.getAction("editor.action.formatDocument");
        if (action) {
          action.run().then(send, send);
          return;
        }
      }
      send();
    },

    setLanguage: function (langId) {
      if (!editor) return;
      monaco.editor.setModelLanguage(editor.getModel(), langId || "plaintext");
    },

    setTheme: function (themeId) {
      if (!editor) return;
      monaco.editor.setTheme(themeId);
    },

    setFont: function (fontFamily, fontSize) {
      if (!editor) return;
      var opts = {};
      if (fontFamily) opts.fontFamily = fontFamily;
      if (fontSize) opts.fontSize = fontSize;
      editor.updateOptions(opts);
    },

    setIndent: function (insertSpaces, tabSize) {
      if (!editor) return;
      editor.updateOptions({ insertSpaces: insertSpaces, tabSize: tabSize });
      editor.getModel().updateOptions({ insertSpaces: insertSpaces, tabSize: tabSize });
    },

    setLineEnding: function (eol) {
      if (!editor) return;
      editor.getModel().pushEOL(
        eol === "crlf"
          ? monaco.editor.EndOfLineSequence.CRLF
          : monaco.editor.EndOfLineSequence.LF
      );
    },

    setMinimap: function (enabled) {
      if (!editor) return;
      editor.updateOptions({ minimap: { enabled: enabled } });
    },

    setRenderWhitespace: function (mode) {
      if (!editor) return;
      editor.updateOptions({ renderWhitespace: mode });
    },

    setStickyScroll: function (enabled) {
      if (!editor) return;
      editor.updateOptions({ stickyScroll: { enabled: enabled } });
    },

    setFontLigatures: function (enabled) {
      if (!editor) return;
      editor.updateOptions({ fontLigatures: enabled });
    },

    setLineNumbers: function (mode) {
      if (!editor) return;
      editor.updateOptions({ lineNumbers: mode });
    },

    setCustomOptions: function (opts) {
      if (!editor || !opts || typeof opts !== "object") return;
      var split = splitCustomOptions(opts);
      applyServiceOptions(split.services);
      editor.updateOptions(split.editor);
    },

    typeText: function (text) {
      if (!editor) return;
      editor.trigger("keyboard", "type", { text: text });
    },

    toggleWrap: function () {
      if (!editor) return;
      var current = editor.getOption(monaco.editor.EditorOption.wordWrap);
      var next = current === "on" ? "off" : "on";
      editor.updateOptions({ wordWrap: next });
      postMessage("wrap-changed", { wordWrap: next === "on" });
    },

    showFind: function () {
      if (!editor) return;
      editor.getAction("actions.find").run();
    },

    showReplace: function () {
      if (!editor) return;
      editor.getAction("editor.action.startFindReplaceAction").run();
    },

    hideFind: function () {
      if (!editor) return;
      editor.trigger("edith", "closeFindWidget", {});
    },

    gotoLine: function (lineNumber) {
      if (!editor) return;
      var line = Math.max(1, (lineNumber || 0) + 1);
      editor.revealLineInCenter(line);
      editor.setPosition({ lineNumber: line, column: 1 });
      editor.focus();
    },

    markClean: function () {
      if (!editor) return;
      cleanVersionId = editor.getModel().getAlternativeVersionId();
      if (lastModifiedState) {
        lastModifiedState = false;
        postMessage("modified-changed", { modified: false });
      }
    },

    // Force the dirty flag on — used after crash recovery, where the restored
    // buffer intentionally differs from the file on disk.
    markDirty: function () {
      if (!editor) return;
      cleanVersionId = null;
      if (!lastModifiedState) {
        lastModifiedState = true;
        postMessage("modified-changed", { modified: true });
      }
    },

    isModified: function () {
      if (!editor) return false;
      return editor.getModel().getAlternativeVersionId() !== cleanVersionId;
    },

    toggleLineComment: function () {
      if (!editor) return;
      editor.getAction("editor.action.commentLine").run();
    },

    triggerAction: function (actionId) {
      if (!editor) return;
      editor.trigger("keyboard", actionId);
    },
  };
})();
