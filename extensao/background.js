/* NIOGEN | extensao/background.js | 06/11/2026 — Claude Code (prompt 28)
 * Service worker: o painel lateral só existe em https://pap.niointernet.com.br/administrativo/* ; em qualquer outra aba fica desligado.
 * Não lê nem guarda dado de cliente, não loga nada.
 */
'use strict';

const PORTAL = /^https:\/\/pap\.niointernet\.com\.br\/administrativo(\/|$)/;

chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
chrome.sidePanel.setOptions({ enabled: false }).catch(() => {});

async function ajusta(tabId, url) {
  const ligado = PORTAL.test(url || '');
  try {
    await chrome.sidePanel.setOptions({ tabId, path: 'panel.html', enabled: ligado });
  } catch (e) { /* aba fechada no meio */ }
}

chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.url || info.status === 'complete') ajusta(tabId, tab.url);
});
chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try { const tab = await chrome.tabs.get(tabId); ajusta(tabId, tab.url); } catch (e) { /* aba fechada */ }
});
chrome.runtime.onInstalled.addListener(async () => {
  const abas = await chrome.tabs.query({ url: 'https://pap.niointernet.com.br/administrativo/*' });
  abas.forEach((t) => ajusta(t.id, t.url));
});

// 0.6.0 (12/11/2026): as travas de rede da condução até o Resumo são regras de SESSÃO presas à aba do portal (o painel liga e
// desliga). Cinto de segurança: aba fechada ou extensão recarregada → nenhuma regra fica para trás.
const IDS_CONDUCAO = Array.from({ length: 300 }, (_, i) => 7300 + i);
async function limpaTravas(tabId) {
  try {
    const regras = await chrome.declarativeNetRequest.getSessionRules();
    const ids = regras.filter((r) => IDS_CONDUCAO.includes(r.id) && (tabId == null || ((r.condition || {}).tabIds || []).includes(tabId))).map((r) => r.id);
    if (ids.length) await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: ids });
  } catch (e) { /* sem regras */ }
}
chrome.tabs.onRemoved.addListener((tabId) => { limpaTravas(tabId); });
chrome.runtime.onStartup.addListener(() => { limpaTravas(null); });
chrome.runtime.onInstalled.addListener(() => { limpaTravas(null); });
