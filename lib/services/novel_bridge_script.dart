/// JS-мост между новеллой на Monogatari и Flutter-кодом.
///
/// Скрипт внедряется в WebView на `onPageStarted`/`onPageFinished` (см.
/// `ReaderScreen`) и делает три вещи:
///
/// 1. **Хук самой новеллы.** Определяет `window.sendVaelGoal(...)`, который
///    скрипт новеллы вызывает в конце каждой главы
///    (`sendVaelGoal('read_chapter_1')` → сразу `'jump scene_2'`).
///    Без этой функции Monogatari падает с ошибкой
///    `window.sendVaelGoal is not a function`.
/// 2. **Пауза/возобновление.** `window.VaelReader.hold()` синхронно
///    останавливает озвучку, снимает все таймеры страницы и подменяет
///    экшен `Jump`, чтобы движок не уехал в следующую главу.
///    `window.VaelReader.release()` снимает паузу и выполняет отложенный
///    переход — чтение продолжается ровно со следующей главы.
/// 3. **События в Dart.** Всё, что происходит, уходит в канал `VaelBridge`
///    (`novel_goal`, `reading_held`, `reading_resumed`, `bridge_error`).
///
/// Плюс фолбэк: если новелла не зовёт `sendVaelGoal`, номер главы
/// вытаскивается из лейбла Monogatari (`scene_1` → 1, `scene_2` → 2) и
/// переход на следующую главу ловится поллингом.
class NovelBridgeScript {
  const NovelBridgeScript._();

  /// Имя JavaScript-канала, на который подписан `ReaderScreen`.
  static const String channelName = 'VaelBridge';

  /// Скрипт для внедрения через `runJavaScript`.
  static const String installer = r'''
(function () {
  if (window.__vaelBridgeInstalled) {
    return;
  }
  window.__vaelBridgeInstalled = true;

  var currentChapter = null; // номер главы, в которой находится читатель
  var lastLabel = null;      // последний известный лейбл Monogatari
  var reported = false;      // завершение главы отправляем один раз

  // Конфиг «платного гейта», приходит из Dart через VaelReader.setGate().
  var gate = { enabled: false, freeChapter: 1 };
  var gateHandled = false;

  // Состояние паузы.
  var paused = false;
  var pendingJump = null;    // переход, который движок попытался сделать на паузе
  var guardsInstalled = false;

  function post(payload) {
    try {
      if (window.VaelBridge && window.VaelBridge.postMessage) {
        window.VaelBridge.postMessage(JSON.stringify(payload));
      }
    } catch (e) { /* канал ещё не готов — молча игнорируем */ }
  }

  // ---------------------------------------------------------------------------
  // Учёт таймеров: без этого новелла продолжает «тикать» под диалогом
  // (автопереход в main.js новеллы работает через setTimeout).
  // ---------------------------------------------------------------------------
  var trackedTimers = {};
  var nativeSetTimeout = window.setTimeout;

  window.setTimeout = function (callback, delay) {
    if (typeof callback !== 'function') {
      return nativeSetTimeout.apply(window, arguments);
    }
    var id = nativeSetTimeout.call(window, function () {
      delete trackedTimers[id];
      return callback.apply(this, arguments);
    }, delay);
    trackedTimers[id] = true;
    return id;
  };

  function clearTrackedTimers() {
    for (var id in trackedTimers) {
      if (!Object.prototype.hasOwnProperty.call(trackedTimers, id)) continue;
      try { window.clearTimeout(Number(id)); } catch (e) {}
      delete trackedTimers[id];
    }
  }

  // ---------------------------------------------------------------------------
  // Звук
  // ---------------------------------------------------------------------------
  function stopPlayer(player) {
    if (!player) return;
    try { if (typeof player.stop === 'function') player.stop(); } catch (e) {}
    try { if (typeof player.pause === 'function') player.pause(); } catch (e) {}
  }

  function stopAllAudio() {
    var engine = window.monogatari;
    if (!engine) return;

    var types = ['music', 'sound', 'soundtrack', 'voice', 'voices', 'ambient'];
    types.forEach(function (type) {
      try {
        var players = typeof engine.mediaPlayers === 'function' ? engine.mediaPlayers(type) : null;
        if (Array.isArray(players)) {
          players.forEach(stopPlayer);
        } else if (players) {
          stopPlayer(players);
        }
      } catch (e) {}
      try {
        if (typeof engine.audio === 'function') engine.audio('stop', type);
      } catch (e) {}
    });

    try {
      if (typeof engine.stopAmbient === 'function') engine.stopAmbient();
    } catch (e) {}
  }

  // ---------------------------------------------------------------------------
  // Перехват перехода между главами.
  //
  // В Monogatari v2 строка скрипта 'jump scene_2' превращается в экшен Jump,
  // а его apply() сам выставляет state({label, step: 0}) и запускает новый
  // лейбл. Поэтому на паузе мы глушим именно Jump: движок остаётся в конце
  // текущей главы, а цель перехода запоминаем.
  // ---------------------------------------------------------------------------
  function installGuards() {
    if (guardsInstalled) return;

    var engine = window.monogatari;
    if (!engine) return;

    var jumpAction = null;
    try {
      var actions = typeof engine.actions === 'function' ? engine.actions() : [];
      for (var i = 0; i < actions.length; i++) {
        if (actions[i] && actions[i].id === 'Jump') {
          jumpAction = actions[i];
          break;
        }
      }
    } catch (e) {}

    if (jumpAction && jumpAction.prototype && typeof jumpAction.prototype.apply === 'function') {
      var originalApply = jumpAction.prototype.apply;
      jumpAction.prototype.apply = function () {
        if (paused) {
          pendingJump = this.label;
          return Promise.resolve();
        }
        return originalApply.apply(this, arguments);
      };
      guardsInstalled = true;
    }
  }

  // ---------------------------------------------------------------------------
  // Пауза / возобновление
  // ---------------------------------------------------------------------------
  function pause() {
    if (paused) return;
    paused = true;

    clearTrackedTimers();

    // Движок ещё не готов (<visual-novel> нет в DOM) — трогать его нельзя,
    // иначе Monogatari покажет модалку "engine:element:not_ready".
    if (!isEngineReady()) return;

    installGuards();
    stopAllAudio();

    // Дополнительно блокируем proceed(): он отваливается, если выставлен
    // _engine_block (внутренняя проверка движка).
    try {
      if (window.monogatari && typeof window.monogatari.global === 'function') {
        window.monogatari.global('_engine_block', true);
      }
    } catch (e) {}
  }

  function resume() {
    var wasPaused = paused;
    paused = false;

    try {
      if (window.monogatari && typeof window.monogatari.global === 'function') {
        window.monogatari.global('_engine_block', false);
      }
    } catch (e) {}

    var target = pendingJump;
    pendingJump = null;

    if (target && window.monogatari && typeof window.monogatari.run === 'function') {
      try {
        // Ровно так же, как это делает сам движок в своём jump-листенере.
        var result = window.monogatari.run('jump ' + target, false);
        if (result && typeof result.catch === 'function') {
          result.catch(function (error) {
            post({ type: 'bridge_error', message: 'resume jump failed: ' + error });
          });
        }
        post({ type: 'reading_resumed', jump: target });
        return;
      } catch (e) {
        post({ type: 'bridge_error', message: 'resume jump failed: ' + e });
      }
    }

    if (wasPaused) {
      post({ type: 'reading_resumed', jump: null });
    }
  }

  // ---------------------------------------------------------------------------
  // Хук новеллы: sendVaelGoal('read_chapter_1')
  // ---------------------------------------------------------------------------
  window.sendVaelGoal = function () {
    var args = Array.prototype.slice.call(arguments);
    var goal = args.length ? args[0] : null;
    var chapter = parseChapter(goal);

    // Пауза обязана быть синхронной: следующим шагом скрипта новеллы идёт
    // 'jump scene_2', и успеть из Dart мы не можем.
    if (gate.enabled && !gateHandled && chapter !== null && chapter <= gate.freeChapter) {
      gateHandled = true;
      pause();
      post({ type: 'reading_held', reason: 'gate' });
    }

    post({
      type: 'novel_goal',
      goal: goal,
      args: args,
      chapter: chapter,
      label: lastLabel
    });
    return true;
  };

  // ---------------------------------------------------------------------------
  // Фолбэк-детект главы по лейблу
  // ---------------------------------------------------------------------------
  function parseChapter(label) {
    if (label === null || label === undefined) {
      return null;
    }
    var match = String(label).match(/(\d+)/);
    if (!match) {
      return null;
    }
    var num = parseInt(match[1], 10);
    return isNaN(num) ? null : num;
  }

  // ВАЖНО: Monogatari v2 при любом обращении к элементам, когда <visual-novel>
  // ещё нет в DOM, показывает модалку "engine:element:not_ready".
  // Пока страница не догрузилась, движок не трогаем вообще.
  function isEngineReady() {
    if (!window.monogatari) return false;
    try {
      return document.querySelector('visual-novel') !== null;
    } catch (e) {
      return false;
    }
  }

  function getLabel() {
    if (!isEngineReady()) return null;
    try {
      if (typeof window.monogatari.state === 'function') {
        var label = window.monogatari.state('label');
        if (label !== undefined && label !== null && label !== '') {
          return label;
        }
      }
    } catch (e) { /* движок ещё не инициализирован */ }
    return null;
  }

  function reportCompletedChapter(chapterNumber) {
    if (reported) return;
    reported = true;
    post({
      type: 'chapter_completed',
      chapter: chapterNumber === null ? 1 : chapterNumber,
      label: lastLabel
    });
  }

  function tick() {
    var label = getLabel();
    if (label === null || label === lastLabel) {
      return;
    }
    lastLabel = label;

    var chapter = parseChapter(label);
    if (chapter === null) {
      return;
    }
    if (currentChapter === null) {
      currentChapter = chapter;
      return;
    }
    if (chapter > currentChapter) {
      var finished = currentChapter;
      currentChapter = chapter;
      reportCompletedChapter(finished);
    }
  }

  // ---------------------------------------------------------------------------
  // Публичный API для вызовов из Dart
  // ---------------------------------------------------------------------------
  window.VaelReader = {
    setGate: function (config) {
      if (!config) return;
      gate.enabled = config.enabled === true;
      if (typeof config.freeChapter === 'number') {
        gate.freeChapter = config.freeChapter;
      }
    },
    hold: function () {
      pause();
      post({ type: 'reading_held', reason: 'host' });
    },
    // Жёсткая остановка: гасим звук и полностью замораживаем новеллу.
    // Используется при уходе с экрана и сворачивании приложения.
    stop: function () {
      pause();
      if (isEngineReady()) stopAllAudio();
      try {
        if (window.__vaelBridgeTimer) {
          clearInterval(window.__vaelBridgeTimer);
        }
      } catch (e) {}
      post({ type: 'reading_stopped' });
    },
    release: function () {
      resume();
    },
    isPaused: function () {
      return paused;
    },
    chapter: function () {
      return currentChapter;
    },
    // Ручная эмуляция события — удобно для проверки paywall-флоу из консоли.
    simulateChapterEnd: function (chapter) {
      reported = false;
      reportCompletedChapter(chapter === undefined ? 1 : chapter);
    }
  };

  tick();
  window.__vaelBridgeTimer = setInterval(tick, 400);
})();
''';

  /// Конфиг гейта: какая глава бесплатная и включён ли гейт вообще.
  static String gateConfig({
    required bool enabled,
    required int freeChapter,
  }) {
    final enabledJs = enabled ? 'true' : 'false';
    return 'window.VaelReader && window.VaelReader.setGate('
        '{"enabled": $enabledJs, "freeChapter": $freeChapter});';
  }

  /// Останавливает новеллу: звук, таймеры и переход в следующую главу.
  static const String hold = 'window.VaelReader && window.VaelReader.hold();';

  /// Жёсткая остановка — при уходе с экрана и сворачивании приложения.
  static const String stop = 'window.VaelReader && window.VaelReader.stop();';

  /// Снимает паузу и выполняет отложенный переход (в начало следующей главы).
  static const String release = 'window.VaelReader && window.VaelReader.release();';
}
