/* diskLIFE Studio · Linux desktop integration
 *
 * The final Studio step explains how to get Windows-AutoPlay-like behaviour on Linux.
 * Linux cannot execute autorun.inf, so the supported route is an XDG autostart entry
 * (user session, no root) running engine/tools/disc-watch.js, which reacts to udisks2
 * events, mounts the disc if needed and asks 启动 / 稍后.
 *
 * The panel is injected at runtime; the Windows Studio never sees it.
 */
(function () {
  'use strict';

  function isEn() {
    return Boolean(window.I18N && window.I18N.lang === 'en');
  }

  function T(zh, en) {
    return isEn() ? en : zh;
  }

  function escapeHtml(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function request(url, options) {
    return fetch(url, Object.assign({
      headers: { 'Content-Type': 'application/json' },
    }, options || {})).then(function (response) {
      return response.json();
    });
  }

  function waitForPanel(callback, tries) {
    var panel = document.querySelector('[data-panel="7"]');
    if (panel) { callback(panel); return; }
    if (tries <= 0) return;
    setTimeout(function () { waitForPanel(callback, tries - 1); }, 200);
  }

  function toolLine(info) {
    var labels = [
      ['udisks2', 'udisks2'],
      ['glib', 'glib2'],
      ['zenity', 'zenity'],
      ['xdgOpen', 'xdg-utils'],
    ];
    var parts = labels.map(function (item) {
      return item[1] + (info.tools[item[0]] ? ' ✓' : ' ✗');
    });
    if (!info.tools.zenity && info.tools.kdialog) parts[2] = 'kdialog ✓';
    if (!info.tools.zenity && !info.tools.kdialog && info.tools.notifySend) parts[2] = 'notify-send ✓';
    return parts.join(' · ');
  }

  function render(info) {
    var panel = document.querySelector('[data-panel="7"]');
    if (!panel) return;
    var card = document.getElementById('linux-integration');
    if (!card) return;

    var distro = info.distro || {};
    var autostart = info.autostart || {};
    document.getElementById('linux-intro').textContent = T(
      'Linux 没有 AutoPlay：光盘插入后系统不会执行 autorun.inf。启用下面的登录自启后，会在你的用户会话里常驻一个守望者，' +
      '通过 udisks2 事件发现插盘、必要时自动挂载，并弹出「启动 / 稍后」。不需要 root。',
      'Linux has no AutoPlay: a mounted disc never executes autorun.inf. Enable the autostart below and a watcher ' +
      'runs in your session, reacts to udisks2 events, mounts the disc if needed, and asks 启动 / 稍后. No root needed.'
    );
    document.getElementById('linux-distro').textContent = T(
      '发行版：', 'Distro: '
    ) + (distro.pretty || 'Linux') +
      (distro.packageManager ? ' · ' + T('包管理器：', 'package manager: ') + distro.packageManager : '') +
      ' · ' + T('事件源：', 'event source: ') + (info.eventSource || 'polling');
    document.getElementById('linux-deps').textContent = T('依赖：', 'Dependencies: ') + toolLine(info);
    document.getElementById('linux-state').textContent =
      T('登录自启：', 'Autostart: ') + (autostart.installed ? T('已启用', 'enabled') : T('未启用', 'not enabled')) +
      ' · ' + T('守望者：', 'watcher: ') + (autostart.running ? T('运行中 (PID ' + autostart.running + ')', 'running (PID ' + autostart.running + ')') : T('未运行', 'not running'));

    var installRow = document.getElementById('linux-install-row');
    var installCmd = document.getElementById('linux-install-cmd');
    var installActions = document.getElementById('linux-install-actions');
    var downloadLink = document.getElementById('linux-link-download');
    if (info.installCommand) {
      installRow.hidden = false;
      installCmd.textContent = info.installCommand;
      installActions.hidden = false;
      var packageUrl = (info.distro && info.distro.packageUrl) || '';
      if (packageUrl) {
        downloadLink.href = packageUrl;
        downloadLink.hidden = false;
      } else {
        downloadLink.hidden = true;
      }
    } else {
      installRow.hidden = true;
      installCmd.textContent = '';
      installActions.hidden = true;
    }

    var autostartBtn = document.getElementById('linux-btn-autostart');
    autostartBtn.textContent = autostart.installed
      ? T('关闭登录自启', 'Disable autostart')
      : T('启用登录自启', 'Enable autostart');
    var startBtn = document.getElementById('linux-btn-start');
    startBtn.textContent = autostart.running
      ? T('停止守望者', 'Stop watcher')
      : T('现在启动守望者', 'Start watcher now');
  }

  function legacyCopy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', 'readonly');
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(area);
    return ok;
  }

  function copyInstallCommand() {
    var button = document.getElementById('linux-btn-copy');
    var command = document.getElementById('linux-install-cmd').textContent || '';
    if (!command) return;
    var done = function (ok) {
      if (!button) return;
      button.textContent = ok ? T('已复制', 'Copied') : T('复制失败', 'Copy failed');
      setTimeout(function () {
        button.textContent = T('复制命令', 'Copy command');
      }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(command).then(function () { done(true); }, function () { done(legacyCopy(command)); });
    } else {
      done(legacyCopy(command));
    }
  }

  function setBusy(busy) {
    ['linux-btn-autostart', 'linux-btn-start'].forEach(function (id) {
      var button = document.getElementById(id);
      if (button) button.disabled = busy;
    });
  }

  function showOutput(text) {
    var pre = document.getElementById('linux-output');
    if (!pre) return;
    pre.textContent = String(text || '').trim().split('\n').slice(-12).join('\n');
  }

  function refresh() {
    return request('/api/linux/integration').then(function (info) {
      if (!info || !info.ok || info.platform !== 'linux') {
        var card = document.getElementById('linux-integration');
        if (card) card.remove();
        return null;
      }
      render(info);
      return info;
    }).catch(function () { /* Studio on another platform: no panel */ });
  }

  function act(action) {
    setBusy(true);
    showOutput(T('正在执行…', 'Working…'));
    request('/api/linux/autostart', {
      method: 'POST',
      body: JSON.stringify({ action: action }),
    }).then(function (result) {
      showOutput((result && result.output) || '');
      return refresh();
    }).catch(function (error) {
      showOutput(String(error && error.message ? error.message : error));
    }).then(function () {
      setBusy(false);
    });
  }

  function buildPanel(panel) {
    if (document.getElementById('linux-integration')) return;
    var card = document.createElement('div');
    card.className = 'ship';
    card.id = 'linux-integration';
    card.innerHTML = [
      '<div class="ship-step">',
      '  <b>L</b>',
      '  <div>',
      '    <h3>' + escapeHtml(T('Linux：插盘自动启动', 'Linux: start on disc insert')) + '</h3>',
      '    <p id="linux-intro"></p>',
      '    <p class="hint tight" id="linux-distro"></p>',
      '    <p class="hint tight" id="linux-deps"></p>',
      '    <p class="hint tight" id="linux-state"></p>',
      '    <p class="hint tight" id="linux-install-row" hidden>' +
      escapeHtml(T('缺少依赖时，可用对应发行版命令安装：', 'Missing dependencies — install them with:')) +
      '<br><code id="linux-install-cmd" style="font-family:var(--mono);font-size:11.5px"></code>' +
      '<span id="linux-install-actions" hidden> ' +
      '<button class="btn ghost" id="linux-btn-copy" type="button"></button> ' +
      '<a class="btn ghost" id="linux-link-download" target="_blank" rel="noopener"></a>' +
      '</span></p>',
      '  </div>',
      '  <div class="burn-row">',
      '    <button class="btn" id="linux-btn-autostart"></button>',
      '    <button class="btn ghost" id="linux-btn-start"></button>',
      '  </div>',
      '</div>',
      '<pre id="linux-output" class="hint tight" style="white-space:pre-wrap;max-height:9em;overflow:auto;font-family:var(--mono);font-size:11px;margin:0"></pre>',
    ].join('');
    var checks = panel.querySelector('#checks');
    if (checks && checks.parentNode === panel) panel.insertBefore(card, checks);
    else panel.appendChild(card);

    document.getElementById('linux-btn-copy').textContent = T('复制命令', 'Copy command');
    document.getElementById('linux-btn-copy').addEventListener('click', copyInstallCommand);
    var download = document.getElementById('linux-link-download');
    download.textContent = T('打开下载页面', 'Open download page');
    download.addEventListener('click', function (event) {
      if (!download.getAttribute('href')) event.preventDefault();
    });
    document.getElementById('linux-btn-autostart').addEventListener('click', function () {
      var installed = document.getElementById('linux-btn-autostart').textContent.indexOf(T('关闭', 'Disable')) >= 0;
      act(installed ? 'uninstall' : 'install');
    });
    document.getElementById('linux-btn-start').addEventListener('click', function () {
      var running = document.getElementById('linux-btn-start').textContent.indexOf(T('停止', 'Stop')) >= 0;
      act(running ? 'stop' : 'start');
    });
  }

  function boot() {
    waitForPanel(function (panel) {
      request('/api/linux/integration').then(function (info) {
        if (!info || !info.ok || info.platform !== 'linux' || info.supported === false) return;
        buildPanel(panel);
        render(info);
      }).catch(function () { /* not the Linux Studio */ });
    }, 20);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
}());
