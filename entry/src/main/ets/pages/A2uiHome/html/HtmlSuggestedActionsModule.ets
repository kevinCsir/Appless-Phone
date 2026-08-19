import {
  A2uiAction,
  SUGGESTED_ACTION_REASON_PYTHON_CODE_GENERATING,
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

function suggestedActionId(action: A2uiAction): string {
  if (action.args === undefined || action.args === null) {
    return '';
  }
  const args = action.args as SuggestedActionRunArgs;
  return typeof args.suggestedActionId === 'string' ? args.suggestedActionId.trim() : '';
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
    const isGeneratingCode: boolean = status.status === 'preparing' &&
      status.reasonCode === SUGGESTED_ACTION_REASON_PYTHON_CODE_GENERATING;
    if (status.status !== 'ready' && !isGeneratingCode) {
      return;
    }
    const item = panelItem(status);
    if (isGeneratingCode || item.action !== undefined) {
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
  const actionSuggestedId = suggestedActionId(action);
  if (action.id !== 'suggested-action.run' || action.kind !== 'client' ||
    actionSuggestedId.length === 0) {
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
        item.action.id === action.id && item.action.kind === action.kind &&
        item.suggestedActionId === actionSuggestedId &&
        suggestedActionId(item.action) === actionSuggestedId) {
        return true;
      }
    }
  } catch (_error) {
  }
  return false;
}

export const SUGGESTED_ACTIONS_CSS: string = `
.suggested-actions-panel {
  margin-top: 12px;
}
.suggested-actions-list {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.suggested-action-button {
  position: relative;
  display: flex;
  flex: 0 1 auto;
  align-items: center;
  justify-content: center;
  min-width: 0;
  min-height: 40px;
  padding: 6px 13px 10px;
  border: 1px solid var(--line);
  border-radius: 999px;
  color: var(--kind-accent, var(--accent));
  background: var(--kind-soft, var(--accent-soft));
  font: inherit;
  box-shadow: none;
}
.suggested-action-button:active {
  transform: scale(0.98);
}
.suggested-action-button[data-status="generating-code"] {
  border-color: rgba(91, 71, 178, 0.24);
  color: #5b47b2;
  background: rgba(116, 91, 214, 0.12);
}
.suggested-action-button:disabled {
  cursor: default;
  opacity: 1;
}
.suggested-action-title {
  max-width: 100%;
  font-size: 13px;
  font-weight: 650;
  line-height: 1.15;
  overflow-wrap: anywhere;
  text-align: center;
}
.suggested-action-meta {
  position: absolute;
  right: 10px;
  bottom: 2px;
  font-size: 7px;
  font-weight: 650;
  line-height: 1;
  opacity: 0.72;
  white-space: nowrap;
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
    var visibleItems = items.filter(function (item) {
      var status = text(item && item.status);
      return (status === 'ready' && item && item.action && typeof item.action === 'object') ||
        (status === 'preparing' && text(item && item.reasonCode) ===
          'PYTHON_CODE_GENERATING');
    });
    state.host.hidden = visibleItems.length === 0;
    if (visibleItems.length === 0) {
      return;
    }
    visibleItems.forEach(function (item) {
      if (text(item.status) === 'preparing') {
        var generatingButton = add(listHost, 'button', 'suggested-action-button');
        generatingButton.type = 'button';
        generatingButton.disabled = true;
        generatingButton.setAttribute('data-status', 'generating-code');
        add(generatingButton, 'span', 'suggested-action-title', text(item.goal));
        add(generatingButton, 'span', 'suggested-action-meta', '代码动态生成中');
        return;
      }
      var action = item.action;
      var button = add(listHost, 'button', 'suggested-action-button');
      button.type = 'button';
      button.setAttribute('data-status', 'ready');
      button.setAttribute('data-suggested-action-id', text(item.suggestedActionId));
      add(button, 'span', 'suggested-action-title', text(action.label));
      add(button, 'span', 'suggested-action-meta', 'ai-suggest');
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
