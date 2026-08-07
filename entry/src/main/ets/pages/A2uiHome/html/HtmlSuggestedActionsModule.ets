import {
  A2uiAction,
  SuggestedActionStatusPayload
} from '@loop/agent-core';

export interface SuggestedActionPanelItem {
  suggestedActionId: string;
  goal: string;
  label: string;
  status: 'preparing' | 'ready' | 'unsupported' | 'failed';
  reasonCode: string;
  action?: A2uiAction;
}

export interface SuggestedActionsPanelPayload {
  version: number;
  surfaceId: string;
  revision: number;
  items: SuggestedActionPanelItem[];
}

interface SuggestedActionRunArgs {
  suggestedActionId: string;
}

function actionForStatus(status: SuggestedActionStatusPayload): A2uiAction | undefined {
  if (status.status !== 'ready' || status.label.trim().length === 0) {
    return undefined;
  }
  const args: SuggestedActionRunArgs = {
    suggestedActionId: status.suggestedActionId
  };
  const action: A2uiAction = {
    id: 'suggested-action.run',
    label: status.label,
    prompt: status.suggestedActionId,
    variant: 'ai-suggested',
    kind: 'client',
    args
  };
  return action;
}

function panelItem(status: SuggestedActionStatusPayload): SuggestedActionPanelItem {
  const item: SuggestedActionPanelItem = {
    suggestedActionId: status.suggestedActionId,
    goal: status.goal,
    label: status.label,
    status: status.status,
    reasonCode: status.reasonCode
  };
  const action = actionForStatus(status);
  if (action !== undefined) {
    item.action = action;
  }
  return item;
}

export function suggestedActionsPanelPayload(
  surfaceId: string,
  revision: number,
  statuses: SuggestedActionStatusPayload[]
): SuggestedActionsPanelPayload {
  const items: SuggestedActionPanelItem[] = [];
  statuses.forEach((status: SuggestedActionStatusPayload): void => {
    if (status.status !== 'ready') {
      return;
    }
    const item = panelItem(status);
    if (item.action !== undefined) {
      items.push(item);
    }
  });
  return {
    version: 1,
    surfaceId,
    revision,
    items
  };
}

export function suggestedActionsPanelAllowsAction(
  payloadJson: string,
  action: A2uiAction,
  surfaceId: string
): boolean {
  if (action.id !== 'suggested-action.run' || action.args === undefined) {
    return false;
  }
  try {
    const payload = JSON.parse(payloadJson) as SuggestedActionsPanelPayload;
    if (payload === null || payload.version !== 1 || payload.surfaceId !== surfaceId ||
      !Array.isArray(payload.items)) {
      return false;
    }
    for (let index = 0; index < payload.items.length; index++) {
      const item = payload.items[index];
      if (item.status === 'ready' && item.action !== undefined &&
        JSON.stringify(item.action) === JSON.stringify(action)) {
        return true;
      }
    }
  } catch (_error) {
  }
  return false;
}

export const SUGGESTED_ACTIONS_CSS: string = `
.suggested-actions-panel {
  margin-top: 14px;
  padding: 13px;
  border: 1px solid rgba(116, 91, 255, 0.20);
  border-radius: 16px;
  background: linear-gradient(145deg, rgba(247, 245, 255, 0.96), rgba(255, 255, 255, 0.92));
  box-shadow: 0 10px 28px rgba(69, 51, 140, 0.08);
}
.suggested-actions-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 10px;
  color: #493f68;
  font-size: 13px;
  font-weight: 800;
  letter-spacing: 0.04em;
}
.suggested-actions-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 24px;
  height: 20px;
  padding: 0 7px;
  border-radius: 999px;
  color: #fff;
  background: #7258d8;
  font-size: 10px;
  letter-spacing: 0.08em;
}
.suggested-actions-list {
  display: grid;
  gap: 8px;
}
.suggested-action-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  min-height: 42px;
  padding: 9px 10px;
  border: 1px solid transparent;
  border-radius: 12px;
  font-size: 13px;
}
.suggested-action-item[data-status="ready"] {
  color: #22613c;
  border-color: #b9dec7;
  background: #ecf8f0;
}
.suggested-action-copy {
  min-width: 0;
  flex: 1;
  line-height: 1.4;
  overflow-wrap: anywhere;
}
.suggested-action-button {
  flex: 0 0 auto;
  min-width: 52px;
  min-height: 34px;
  padding: 7px 14px;
  border: 1px solid #abd7bc;
  border-radius: 10px;
  color: #185b35;
  background: #e7f7ed;
  font: inherit;
  font-size: 13px;
  font-weight: 750;
  text-align: center;
}
.suggested-action-button:active {
  background: #d9f0e2;
}
`;

export const SUGGESTED_ACTIONS_JS: string = `
(function () {
  var state = { surfaceId: '', revision: -1, payload: null, host: null };
  function text(value) {
    return value === undefined || value === null ? '' : String(value);
  }
  function list(value) {
    return Array.isArray(value) ? value : [];
  }
  function add(parent, tag, className, value) {
    var node = document.createElement(tag);
    if (className) { node.className = className; }
    if (text(value).length > 0) { node.textContent = text(value); }
    parent.appendChild(node);
    return node;
  }
  function postAction(action) {
    try {
      if (window.AIPhoneHome && typeof window.AIPhoneHome.postAction === 'function') {
        window.AIPhoneHome.postAction(JSON.stringify(action));
      }
    } catch (error) {}
  }
  function render() {
    if (!state.host) { return; }
    var listHost = state.host.querySelector('.suggested-actions-list');
    if (!listHost) { return; }
    listHost.textContent = '';
    var items = state.payload ? list(state.payload.items) : [];
    var readyItems = items.filter(function (item) {
      return text(item && item.status) === 'ready' && item && item.action &&
        typeof item.action === 'object';
    });
    state.host.hidden = readyItems.length === 0;
    if (readyItems.length === 0) {
      return;
    }
    readyItems.forEach(function (item) {
      var action = item.action;
      var row = add(listHost, 'div', 'suggested-action-item');
      row.setAttribute('data-status', 'ready');
      add(row, 'div', 'suggested-action-copy', text(action.label));
      var button = add(row, 'button', 'suggested-action-button', 'Go');
      button.type = 'button';
      button.setAttribute('data-suggested-action-id', text(item.suggestedActionId));
      button.addEventListener('click', function () { postAction(action); });
    });
  }
  function mount(parent, surfaceId) {
    state.surfaceId = text(surfaceId);
    var existing = document.getElementById('suggested-actions-panel');
    if (existing) {
      state.host = existing;
      render();
      return existing;
    }
    var panel = add(parent, 'section', 'suggested-actions-panel');
    panel.id = 'suggested-actions-panel';
    var header = add(panel, 'div', 'suggested-actions-header');
    add(header, 'span', 'suggested-actions-badge', 'AI');
    add(header, 'span', '', 'suggest');
    add(panel, 'div', 'suggested-actions-list');
    state.host = panel;
    render();
    return panel;
  }
  function applyLocal(payload) {
    if (!payload || Number(payload.version) !== 1 || !Array.isArray(payload.items) ||
      text(payload.surfaceId).length === 0 || text(payload.surfaceId) !== state.surfaceId) {
      return false;
    }
    var revision = Number(payload.revision);
    if (!Number.isFinite(revision) || revision <= state.revision) { return false; }
    state.revision = revision;
    state.payload = payload;
    render();
    return true;
  }
  function applyToFrames(payload) {
    var applied = false;
    Array.prototype.forEach.call(document.querySelectorAll('iframe'), function (frame) {
      try {
        var childApply = frame.contentWindow && frame.contentWindow.__aiphoneApplySuggestedActions;
        if (typeof childApply === 'function') {
          if (childApply(payload, true)) { applied = true; }
          return;
        }
        frame.addEventListener('load', function () {
          try {
            var loadedApply = frame.contentWindow && frame.contentWindow.__aiphoneApplySuggestedActions;
            if (typeof loadedApply === 'function') { loadedApply(payload, true); }
          } catch (error) {}
        }, { once: true });
      } catch (error) {}
    });
    return applied;
  }
  function apply(raw, fromParent) {
    var payload = raw;
    try {
      if (typeof raw === 'string') { payload = JSON.parse(raw); }
    } catch (error) { return false; }
    if (fromParent === true && payload && state.surfaceId.length > 0) {
      payload = {
        version: payload.version,
        surfaceId: state.surfaceId,
        revision: payload.revision,
        items: payload.items
      };
    }
    var applied = applyLocal(payload);
    var frameApplied = applyToFrames(payload);
    [50, 200, 500].forEach(function (delay) {
      window.setTimeout(function () { applyToFrames(payload); }, delay);
    });
    return frameApplied || applied;
  }
  window.AIPhoneSuggestedActions = { mount: mount };
  window.__aiphoneApplySuggestedActions = apply;
})();
`;
