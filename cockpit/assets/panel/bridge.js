// Ponte dos arquivos `.panel` (plano 67). Injetada pelo app no início do
// documento; a página só vê `window.cockpit`.
//
//   const r = await cockpit("exec git status --short");
//   r.ok, r.code, r.stdout, r.stderr, r.json (stdout parseado quando é JSON)
//   cockpit.on("theme", vars => ...)   // troca de tema do app
//   cockpit.theme                       // as CSS variables --ckp-* atuais
(function () {
  if (window.cockpit) return;
  var listeners = {};

  function ready() {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      return Promise.resolve();
    }
    return new Promise(function (resolve) {
      window.addEventListener('flutterInAppWebViewPlatformReady', function () {
        resolve();
      }, { once: true });
    });
  }

  function cockpit(line) {
    return ready().then(function () {
      return window.flutter_inappwebview.callHandler('cockpit', String(line));
    });
  }

  cockpit.on = function (event, fn) {
    (listeners[event] = listeners[event] || []).push(fn);
    return function () {
      listeners[event] = (listeners[event] || []).filter(function (f) {
        return f !== fn;
      });
    };
  };

  cockpit.theme = {};

  cockpit.__emit = function (event, data) {
    (listeners[event] || []).forEach(function (fn) {
      try {
        fn(data);
      } catch (e) {
        console.error(e);
      }
    });
  };

  cockpit.__setTheme = function (vars) {
    cockpit.theme = vars;
    var root = document.documentElement;
    for (var k in vars) root.style.setProperty(k, vars[k]);
    cockpit.__emit('theme', vars);
  };

  window.cockpit = cockpit;
})();
