<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, useTemplateRef } from 'vue';
import { z } from 'zod';
import { useSelene, type ClientNetworkPayload, type Coordinate } from './selene';
import RegistryVisual from './RegistryVisual.vue';

const emptyTableAsArray = (value: unknown): unknown =>
  value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 0 ? [] : value;
const registryOptionSchema = z.object({ value: z.string(), label: z.string(), visual: z.string().optional() });
const registryOptionsSchema = z.preprocess(emptyTableAsArray, z.array(registryOptionSchema));
const enumOptionSchema = z.object({ value: z.string(), label: z.string() });
const targetOptionSchema = z.object({
  value: z.string(),
  label: z.string(),
  visual: z.string().optional(),
  offline: z.boolean(),
  default: z.boolean(),
});
const targetOptionsSchema = z.preprocess(emptyTableAsArray, z.array(targetOptionSchema));

const parameterSchema = z.discriminatedUnion('type', [
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('number'),
    required: z.boolean(),
    default: z.number().optional(),
    min: z.number().optional(),
    max: z.number().optional(),
    step: z.number().positive().optional(),
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('string'),
    required: z.boolean(),
    default: z.string().optional(),
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('message'),
    required: z.boolean(),
    default: z.string().optional(),
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('boolean'),
    required: z.boolean(),
    default: z.boolean().optional(),
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('enum'),
    required: z.boolean(),
    default: z.string().optional(),
    options: z.array(enumOptionSchema).min(1),
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('coordinate'),
    required: z.boolean(),
    default: z.object({ x: z.number(), y: z.number(), z: z.number() }).optional(),
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('registry'),
    required: z.boolean(),
    registry: z.string(),
    deferred: z.boolean(),
    default: z.string().optional(),
    options: registryOptionsSchema,
  }),
  z.object({
    name: z.string(),
    label: z.string(),
    type: z.literal('target'),
    required: z.boolean(),
    resolver: z.string(),
    requireOnline: z.boolean(),
    deferred: z.boolean(),
    optionSet: z.string(),
    default: z.string().optional(),
    options: targetOptionsSchema,
  }),
]);

const actionSchema = z.object({
  id: z.string(),
  label: z.string(),
  description: z.string().optional(),
  parameters: z.preprocess(emptyTableAsArray, z.array(parameterSchema)),
});

const actionsPayloadSchema = z.object({
  actions: z.array(actionSchema),
  targetOptions: z.record(z.string(), targetOptionsSchema),
});
const resultPayloadSchema = z.object({
  actionId: z.string(),
  success: z.boolean(),
  message: z.string(),
});
const registryOptionsPayloadSchema = z.object({
  actionId: z.string(),
  parameterName: z.string(),
  query: z.string(),
  options: registryOptionsSchema,
});
const targetOptionsPayloadSchema = z.object({
  actionId: z.string(),
  parameterName: z.string(),
  query: z.string(),
  options: targetOptionsSchema,
});

type AdminAction = z.infer<typeof actionSchema>;
type RegistryParameter = Extract<AdminAction['parameters'][number], { type: 'registry' | 'target' }>;
type EnumParameter = Extract<AdminAction['parameters'][number], { type: 'enum' }>;
type CoordinateInput = { x: number | undefined; y: number | undefined; z: number | undefined };
type ParameterValue = string | number | boolean | CoordinateInput | undefined;

const alwaysKeepMenuOpenAfterExecute = true;
const favoriteActionsStorageKey = 'moonlight-admin:favorite-actions';

function loadFavoriteActionIds(): string[] {
  try {
    const stored = JSON.parse(localStorage.getItem(favoriteActionsStorageKey) ?? '[]');
    return Array.isArray(stored) ? stored.filter((id): id is string => typeof id === 'string') : [];
  } catch {
    return [];
  }
}

const selene = useSelene();
const isOpen = ref(false);
const actions = ref<AdminAction[]>([]);
const favoriteActionIds = ref(loadFavoriteActionIds());
const searchQuery = ref('');
const searchInput = useTemplateRef<HTMLInputElement>('searchInput');
const actionsList = useTemplateRef<HTMLElement>('actionsList');
const expandedActionId = ref<string | null>(null);
const values = reactive<Record<string, Record<string, ParameterValue>>>({});
const executingActionId = ref<string | null>(null);
const closeOnSuccessActionId = ref<string | null>(null);
const result = ref<{ actionId: string; success: boolean; message: string } | null>(null);
const openRegistryKey = ref<string | null>(null);
const openEnumKey = ref<string | null>(null);
const registryQueries = reactive<Record<string, string>>({});
const includeOffline = reactive<Record<string, boolean>>({});
const pickingCoordinate = ref<{ actionId: string; parameterName: string } | null>(null);

const unsubscribers: Array<() => void> = [];
let releaseMenuKeys: (() => void) | undefined;
let releasePickerKeys: (() => void) | undefined;
let releasePickerPointer: (() => void) | undefined;

const filteredActions = computed(() => {
  const query = searchQuery.value.trim().toLocaleLowerCase();
  if (!query) {
    const favorites = new Set(favoriteActionIds.value);
    return actions.value
      .map((action, index) => ({ action, index }))
      .sort(
        (left, right) =>
          Number(favorites.has(right.action.id)) - Number(favorites.has(left.action.id)) || left.index - right.index,
      )
      .map(({ action }) => action);
  }
  return actions.value
    .map((action) => ({ action, score: actionSearchScore(action, query) }))
    .filter(({ score }) => score > 0)
    .sort((left, right) => right.score - left.score || left.action.label.localeCompare(right.action.label))
    .map(({ action }) => action);
});
const unmatchedActionsCount = computed(() =>
  searchQuery.value.trim() ? actions.value.length - filteredActions.value.length : 0,
);

function textSearchScore(value: string | undefined, query: string): number {
  if (!value) {
    return 0;
  }
  const normalized = value.toLocaleLowerCase();
  if (normalized === query) {
    return 1000;
  }
  if (normalized.startsWith(query)) {
    return 800;
  }
  if (normalized.split(/[^\p{L}\p{N}]+/u).some((word) => word.startsWith(query))) {
    return 600;
  }
  const index = normalized.indexOf(query);
  return index === -1 ? 0 : 400 - index;
}

function actionSearchScore(action: AdminAction, query: string): number {
  return Math.max(
    textSearchScore(action.label, query),
    textSearchScore(action.id, query) * 0.5,
    textSearchScore(action.description, query) * 0.25,
  );
}

function isFavorite(actionId: string): boolean {
  return favoriteActionIds.value.includes(actionId);
}

function toggleFavorite(actionId: string): void {
  favoriteActionIds.value = isFavorite(actionId)
    ? favoriteActionIds.value.filter((id) => id !== actionId)
    : [...favoriteActionIds.value, actionId];
  try {
    localStorage.setItem(favoriteActionsStorageKey, JSON.stringify(favoriteActionIds.value));
  } catch {
    // Favoriting still works for this session when persistent storage is unavailable.
  }
}

function defaultsFor(action: AdminAction): Record<string, ParameterValue> {
  return Object.fromEntries(
    action.parameters.map((parameter) => [
      parameter.name,
      parameter.default ??
        (parameter.type === 'boolean'
          ? false
          : parameter.type === 'coordinate'
            ? { x: undefined, y: undefined, z: undefined }
            : undefined),
    ]),
  );
}

function coordinateValue(action: AdminAction, parameterName: string): CoordinateInput {
  return values[action.id]![parameterName] as CoordinateInput;
}

function finishCoordinatePicker(coordinate?: Coordinate): void {
  const picker = pickingCoordinate.value;
  if (!picker) {
    return;
  }
  if (coordinate) {
    values[picker.actionId]![picker.parameterName] = { ...coordinate };
  }
  releasePickerKeys?.();
  releasePickerPointer?.();
  releasePickerKeys = undefined;
  releasePickerPointer = undefined;
  pickingCoordinate.value = null;
  setMenuOpen(true);
}

function startCoordinatePicker(action: AdminAction, parameterName: string): void {
  setMenuOpen(false);
  pickingCoordinate.value = { actionId: action.id, parameterName };
  releasePickerKeys = selene.input.captureKeys('Escape');
  releasePickerPointer = selene.input.onPointerDown((event) => {
    if (event.button === 0) {
      finishCoordinatePicker(event.coordinate);
    }
  });
}

function requestActions(): void {
  selene.network.sendToServer('moonlight-admin:request-actions');
}

function receiveActions(payload: ClientNetworkPayload): void {
  const parsed = actionsPayloadSchema.safeParse(payload);
  if (!parsed.success) {
    console.error('[Moonlight Admin] Invalid action list', parsed.error);
    return;
  }
  actions.value = parsed.data.actions;
  for (const action of actions.value) {
    for (const parameter of action.parameters) {
      if (parameter.type === 'target') {
        parameter.options = parsed.data.targetOptions[parameter.optionSet] ?? [];
      }
    }
    values[action.id] ??= defaultsFor(action);
    for (const parameter of action.parameters) {
      if (parameter.type === 'registry' || parameter.type === 'target') {
        const key = registryKey(action.id, parameter.name);
        const selected = parameter.options.find((option) => option.value === values[action.id]?.[parameter.name]);
        registryQueries[key] = selected?.label ?? '';
      }
    }
  }
}

function receiveResult(payload: ClientNetworkPayload): void {
  const parsed = resultPayloadSchema.safeParse(payload);
  if (!parsed.success) {
    console.error('[Moonlight Admin] Invalid action result', parsed.error);
    return;
  }
  executingActionId.value = null;
  result.value = parsed.data;
  const shouldClose = parsed.data.success && closeOnSuccessActionId.value === parsed.data.actionId;
  closeOnSuccessActionId.value = null;
  if (shouldClose) {
    setMenuOpen(false);
  }
}

function receiveRegistryOptions(payload: ClientNetworkPayload): void {
  const parsed = registryOptionsPayloadSchema.safeParse(payload);
  if (!parsed.success) {
    console.error('[Moonlight Admin] Invalid registry options', parsed.error);
    return;
  }
  const key = registryKey(parsed.data.actionId, parsed.data.parameterName);
  if ((registryQueries[key] ?? '') !== parsed.data.query) {
    return;
  }
  const action = actions.value.find((candidate) => candidate.id === parsed.data.actionId);
  const parameter = action?.parameters.find((candidate) => candidate.name === parsed.data.parameterName);
  if (parameter?.type === 'registry' && parameter.deferred) {
    parameter.options = parsed.data.options;
  }
}

function receiveTargetOptions(payload: ClientNetworkPayload): void {
  const parsed = targetOptionsPayloadSchema.safeParse(payload);
  if (!parsed.success) {
    console.error('[Moonlight Admin] Invalid target options', parsed.error);
    return;
  }
  const key = registryKey(parsed.data.actionId, parsed.data.parameterName);
  if ((registryQueries[key] ?? '') !== parsed.data.query) {
    return;
  }
  const action = actions.value.find((candidate) => candidate.id === parsed.data.actionId);
  const parameter = action?.parameters.find((candidate) => candidate.name === parsed.data.parameterName);
  if (parameter?.type === 'target' && parameter.deferred) {
    parameter.options = parsed.data.options;
  }
}

function requestChoiceOptions(action: AdminAction, parameter: RegistryParameter): void {
  if (!parameter.deferred) {
    return;
  }
  const query = registryQueries[registryKey(action.id, parameter.name)] ?? '';
  selene.network.sendToServer(
    parameter.type === 'registry' ? 'moonlight-admin:search-registry' : 'moonlight-admin:search-target',
    {
      actionId: action.id,
      parameterName: parameter.name,
      query,
    },
  );
}

async function toggleAction(action: AdminAction, event: MouseEvent): Promise<void> {
  const expanding = expandedActionId.value !== action.id;
  const actionElement = (event.currentTarget as HTMLElement).closest<HTMLElement>('.action');
  expandedActionId.value = expanding ? action.id : null;
  result.value = null;
  if (expanding) {
    await nextTick();
    actionElement?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
}

async function expandFirstAvailableAction(): Promise<void> {
  const action = filteredActions.value[0];
  if (!action) {
    return;
  }
  expandedActionId.value = action.id;
  result.value = null;
  await nextTick();
  actionsList.value?.querySelector<HTMLElement>('.action')?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function registryKey(actionId: string, parameterName: string): string {
  return `${actionId}:${parameterName}`;
}

function selectedEnumLabel(action: AdminAction, parameter: EnumParameter): string {
  return parameter.options.find((option) => option.value === values[action.id]?.[parameter.name])?.label ?? 'Select…';
}

function toggleEnumDropdown(action: AdminAction, parameter: EnumParameter): void {
  const key = registryKey(action.id, parameter.name);
  openRegistryKey.value = null;
  openEnumKey.value = openEnumKey.value === key ? null : key;
}

function selectEnumOption(action: AdminAction, parameter: EnumParameter, value: string | undefined): void {
  values[action.id]![parameter.name] = value;
  openEnumKey.value = null;
}

function closeEnumDropdown(key: string): void {
  window.setTimeout(() => {
    if (openEnumKey.value === key) {
      openEnumKey.value = null;
    }
  });
}

function matchingRegistryOptions(parameter: RegistryParameter, key: string) {
  const query = (registryQueries[key] ?? '').trim().toLocaleLowerCase();
  return parameter.options.filter((option) => {
    if ('offline' in option && option.offline && !includeOffline[key]) {
      return false;
    }
    return (
      !query || option.label.toLocaleLowerCase().includes(query) || option.value.toLocaleLowerCase().includes(query)
    );
  });
}

function toggleOfflineTargets(action: AdminAction, parameter: RegistryParameter): void {
  if (parameter.type !== 'target') {
    return;
  }
  const key = registryKey(action.id, parameter.name);
  includeOffline[key] = !includeOffline[key];
  if (!includeOffline[key]) {
    const selected = parameter.options.find((option) => option.value === values[action.id]?.[parameter.name]);
    if (selected?.offline) {
      values[action.id]![parameter.name] = undefined;
      registryQueries[key] = '';
    }
  }
}

function openRegistryDropdown(action: AdminAction, parameter: RegistryParameter): void {
  const key = registryKey(action.id, parameter.name);
  const selected = parameter.options.find((option) => option.value === values[action.id]?.[parameter.name]);
  registryQueries[key] = selected?.label ?? '';
  openRegistryKey.value = key;
  requestChoiceOptions(action, parameter);
}

function searchRegistryOptions(action: AdminAction, parameter: RegistryParameter, event: Event): void {
  const key = registryKey(action.id, parameter.name);
  registryQueries[key] = (event.target as HTMLInputElement).value;
  values[action.id]![parameter.name] = undefined;
  openRegistryKey.value = key;
  requestChoiceOptions(action, parameter);
}

function selectRegistryOption(
  action: AdminAction,
  parameter: RegistryParameter,
  option: RegistryParameter['options'][number],
): void {
  const key = registryKey(action.id, parameter.name);
  values[action.id]![parameter.name] = option.value;
  registryQueries[key] = option.label;
  openRegistryKey.value = null;
}

function selectFirstRegistryOption(action: AdminAction, parameter: RegistryParameter): void {
  const key = registryKey(action.id, parameter.name);
  const option = matchingRegistryOptions(parameter, key)[0];
  if (option) {
    selectRegistryOption(action, parameter, option);
  }
}

function closeRegistryDropdown(key: string): void {
  window.setTimeout(() => {
    if (openRegistryKey.value === key) {
      openRegistryKey.value = null;
    }
  });
}

function suppliedParameters(action: AdminAction): Record<string, unknown> {
  const actionValues = values[action.id] ?? {};
  const supplied: Record<string, unknown> = {};
  for (const parameter of action.parameters) {
    const value = actionValues[parameter.name];
    if (value === undefined) {
      continue;
    }
    if (parameter.type === 'coordinate') {
      const coordinate = value as CoordinateInput;
      const components = Object.fromEntries(
        (['x', 'y', 'z'] as const)
          .filter((axis) => coordinate[axis] !== undefined)
          .map((axis) => [axis, coordinate[axis]]),
      );
      if (Object.keys(components).length > 0) {
        supplied[parameter.name] = components;
      }
    } else {
      supplied[parameter.name] = value;
    }
  }
  return supplied;
}

function execute(action: AdminAction, keepOpen = false): void {
  executingActionId.value = action.id;
  closeOnSuccessActionId.value = keepOpen || alwaysKeepMenuOpenAfterExecute ? null : action.id;
  result.value = null;
  try {
    selene.network.sendToServer('moonlight-admin:execute', {
      actionId: action.id,
      parameters: suppliedParameters(action),
    });
  } catch (error) {
    executingActionId.value = null;
    closeOnSuccessActionId.value = null;
    result.value = {
      actionId: action.id,
      success: false,
      message: error instanceof Error ? error.message : String(error),
    };
    return;
  }
}

async function focusSearch(): Promise<void> {
  await nextTick();
  searchInput.value?.focus();
  searchInput.value?.select();
}

function setMenuOpen(open: boolean): void {
  isOpen.value = open;
  if (!open) {
    openRegistryKey.value = null;
    closeOnSuccessActionId.value = null;
  }
  releaseMenuKeys?.();
  releaseMenuKeys = open ? selene.input.captureKeys('Escape', 'Enter') : undefined;
  if (open) {
    requestActions();
    void focusSearch();
  }
}

function handleMenuKeydown(event: KeyboardEvent): void {
  if (pickingCoordinate.value) {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopImmediatePropagation();
      finishCoordinatePicker();
    }
    return;
  }
  const shouldExecute = event.key === 'Enter' && event.ctrlKey && isOpen.value;
  const shouldToggle = event.key === 'F2';
  const shouldClose = event.key === 'Escape' && isOpen.value;
  if ((!shouldExecute && !shouldToggle && !shouldClose) || event.repeat) {
    return;
  }
  event.preventDefault();
  event.stopImmediatePropagation();
  if (shouldExecute) {
    const action = actions.value.find((candidate) => candidate.id === expandedActionId.value);
    if (action) {
      execute(action, event.shiftKey);
    }
    return;
  }
  setMenuOpen(shouldClose ? false : !isOpen.value);
}

onMounted(() => {
  unsubscribers.push(
    selene.input.captureKeys('F2'),
    selene.network.onPayload('moonlight-admin:actions', receiveActions),
    selene.network.onPayload('moonlight-admin:result', receiveResult),
    selene.network.onPayload('moonlight-admin:registry-options', receiveRegistryOptions),
    selene.network.onPayload('moonlight-admin:target-options', receiveTargetOptions),
    selene.network.onConnected(requestActions),
  );
  window.addEventListener('keydown', handleMenuKeydown, true);
});

onBeforeUnmount(() => {
  releaseMenuKeys?.();
  releasePickerKeys?.();
  releasePickerPointer?.();
  for (const unsubscribe of unsubscribers) {
    unsubscribe();
  }
  window.removeEventListener('keydown', handleMenuKeydown, true);
});
</script>

<template>
  <main class="layer">
    <div v-if="pickingCoordinate" class="picker-hint" role="status">
      <span>Select a coordinate</span>
      <small>Left click to select · Escape to cancel</small>
    </div>
    <Transition name="roll-down">
      <section v-if="isOpen" class="menu" role="dialog" aria-label="admin menu">
        <header class="header">
          <div>
            <h1>Admin Menu</h1>
          </div>
          <button class="close" type="button" aria-label="Close admin menu" @click="setMenuOpen(false)">×</button>
        </header>

        <div class="search">
          <label for="admin-action-search">Search actions</label>
          <input
            id="admin-action-search"
            ref="searchInput"
            v-model="searchQuery"
            type="search"
            placeholder="Search actions…"
            autocomplete="off"
            @keydown.enter.prevent="expandFirstAvailableAction"
          />
        </div>

        <div ref="actionsList" class="actions">
          <p v-if="actions.length === 0" class="empty">No actions are available.</p>
          <p v-else-if="filteredActions.length === 0" class="empty">No matching actions.</p>
          <article v-for="action in filteredActions" :key="action.id" class="action">
            <div class="action-heading">
              <button
                class="favorite"
                :class="{ active: isFavorite(action.id) }"
                type="button"
                :aria-label="`${isFavorite(action.id) ? 'Remove' : 'Add'} ${action.label} ${
                  isFavorite(action.id) ? 'from' : 'to'
                } favorites`"
                :aria-pressed="isFavorite(action.id)"
                @click="toggleFavorite(action.id)"
              >
                <span aria-hidden="true">{{ isFavorite(action.id) ? '★' : '☆' }}</span>
              </button>
              <button
                class="toggle"
                type="button"
                :aria-expanded="expandedActionId === action.id"
                @click="toggleAction(action, $event)"
              >
                <span>
                  <strong>{{ action.label }}</strong>
                  <small v-if="action.description">{{ action.description }}</small>
                </span>
                <span class="chevron" aria-hidden="true">⌄</span>
              </button>
            </div>

            <form v-if="expandedActionId === action.id" class="form" @submit.prevent="execute(action)">
              <div
                v-for="parameter in action.parameters"
                :key="parameter.name"
                class="field"
                :class="{
                  choice:
                    parameter.type === 'coordinate' || parameter.type === 'registry' || parameter.type === 'target',
                  'full-width': parameter.type === 'message',
                }"
              >
                <span class="field-heading">
                  <span>
                    {{ parameter.label }}
                    <small v-if="!parameter.required" class="optional-label">(optional)</small>
                  </span>
                  <button
                    v-if="parameter.type === 'target' && !parameter.requireOnline"
                    class="offline-toggle"
                    type="button"
                    role="switch"
                    :aria-checked="includeOffline[registryKey(action.id, parameter.name)] === true"
                    @click="toggleOfflineTargets(action, parameter)"
                  >
                    <span aria-hidden="true" />
                    Include Offline
                  </button>
                </span>
                <input
                  v-if="parameter.type === 'number'"
                  v-model.number="values[action.id]![parameter.name]"
                  type="number"
                  :required="parameter.required"
                  :min="parameter.min"
                  :max="parameter.max"
                  :step="parameter.step ?? 'any'"
                />
                <input
                  v-else-if="parameter.type === 'string' || parameter.type === 'message'"
                  v-model="values[action.id]![parameter.name] as string"
                  type="text"
                  :required="parameter.required"
                />
                <input
                  v-else-if="parameter.type === 'boolean'"
                  v-model="values[action.id]![parameter.name] as boolean"
                  class="checkbox"
                  type="checkbox"
                />
                <div v-else-if="parameter.type === 'enum'" class="select">
                  <button
                    class="enum-trigger"
                    type="button"
                    :aria-expanded="openEnumKey === registryKey(action.id, parameter.name)"
                    :aria-controls="`${registryKey(action.id, parameter.name)}-options`"
                    @click="toggleEnumDropdown(action, parameter)"
                    @blur="closeEnumDropdown(registryKey(action.id, parameter.name))"
                  >
                    <span>{{ selectedEnumLabel(action, parameter) }}</span>
                    <span aria-hidden="true">⌄</span>
                  </button>
                  <div
                    v-if="openEnumKey === registryKey(action.id, parameter.name)"
                    :id="`${registryKey(action.id, parameter.name)}-options`"
                    class="options"
                    role="listbox"
                  >
                    <button
                      v-if="!parameter.required"
                      type="button"
                      role="option"
                      :aria-selected="values[action.id]![parameter.name] === undefined"
                      @mousedown.prevent
                      @click="selectEnumOption(action, parameter, undefined)"
                    >
                      None
                    </button>
                    <button
                      v-for="option in parameter.options"
                      :key="option.value"
                      type="button"
                      role="option"
                      :aria-selected="values[action.id]![parameter.name] === option.value"
                      @mousedown.prevent
                      @click="selectEnumOption(action, parameter, option.value)"
                    >
                      {{ option.label }}
                    </button>
                  </div>
                </div>
                <div v-else-if="parameter.type === 'coordinate'" class="coordinate-input">
                  <label v-for="axis in ['x', 'y', 'z'] as const" :key="axis">
                    <span>{{ axis.toUpperCase() }}</span>
                    <input
                      v-model.number="coordinateValue(action, parameter.name)[axis]"
                      type="number"
                      step="1"
                      :required="parameter.required"
                    />
                  </label>
                  <button type="button" class="pick-coordinate" @click="startCoordinatePicker(action, parameter.name)">
                    📌
                  </button>
                </div>
                <div v-else class="select">
                  <input
                    :value="registryQueries[registryKey(action.id, parameter.name)] ?? ''"
                    type="text"
                    role="combobox"
                    autocomplete="off"
                    :required="parameter.required"
                    :aria-expanded="openRegistryKey === registryKey(action.id, parameter.name)"
                    :aria-controls="`${registryKey(action.id, parameter.name)}-options`"
                    :placeholder="parameter.type === 'target' ? 'Search targets…' : 'Search registry…'"
                    @focus="openRegistryDropdown(action, parameter)"
                    @input="searchRegistryOptions(action, parameter, $event)"
                    @blur="closeRegistryDropdown(registryKey(action.id, parameter.name))"
                    @keydown.enter.prevent="selectFirstRegistryOption(action, parameter)"
                    @keydown.down.prevent="selectFirstRegistryOption(action, parameter)"
                  />
                  <div
                    v-if="openRegistryKey === registryKey(action.id, parameter.name)"
                    :id="`${registryKey(action.id, parameter.name)}-options`"
                    class="options"
                    role="listbox"
                  >
                    <button
                      v-for="option in matchingRegistryOptions(parameter, registryKey(action.id, parameter.name))"
                      :key="option.value"
                      type="button"
                      role="option"
                      :aria-selected="values[action.id]![parameter.name] === option.value"
                      @mousedown.prevent
                      @click="selectRegistryOption(action, parameter, option)"
                    >
                      <RegistryVisual v-if="option.visual" :identifier="option.visual" />
                      <span class="option-text">
                        <strong>{{ option.label }}</strong>
                        <small>
                          {{ option.value }}{{ 'offline' in option && option.offline ? ' · Offline' : '' }}
                        </small>
                      </span>
                    </button>
                    <p v-if="matchingRegistryOptions(parameter, registryKey(action.id, parameter.name)).length === 0">
                      No matching entries.
                    </p>
                  </div>
                </div>
              </div>

              <footer class="footer">
                <p
                  v-if="result?.actionId === action.id"
                  class="result"
                  :class="{ error: !result.success }"
                  role="status"
                >
                  {{ result.message }}
                </p>
                <button
                  class="execute"
                  type="button"
                  :disabled="executingActionId === action.id"
                  @click="execute(action, $event.shiftKey)"
                >
                  {{ executingActionId === action.id ? 'Executing…' : 'Execute' }}
                </button>
              </footer>
            </form>
          </article>
          <p v-if="filteredActions.length > 0 && unmatchedActionsCount > 0" class="filtered-count">
            {{ unmatchedActionsCount }} more {{ unmatchedActionsCount === 1 ? 'action' : 'actions' }} not matching
            search filter
          </p>
        </div>
      </section>
    </Transition>
  </main>
</template>

<style scoped>
* {
  box-sizing: border-box;
}
.layer {
  position: absolute;
  inset: 0;
  z-index: 800;
  display: flex;
  justify-content: center;
  pointer-events: none;
  color: #e4e4e7;
  font-family: Inter, ui-sans-serif, system-ui, sans-serif;
  -webkit-user-select: none;
  user-select: none;
}
.layer input,
.layer textarea {
  -webkit-user-select: text;
  user-select: text;
}
.menu {
  display: flex;
  flex-direction: column;
  width: min(720px, calc(100vw - 32px));
  height: min(720px, calc(100vh - 24px));
  max-height: min(720px, calc(100vh - 24px));
  overflow: hidden;
  border: 1px solid rgba(212, 212, 216, 0.2);
  border-top: 4px solid #fb7185;
  border-radius: 0 0 12px 12px;
  background: rgba(24, 24, 27, 0.9);
  backdrop-filter: blur(16px);
  pointer-events: auto;
}
.picker-hint {
  position: absolute;
  top: 18px;
  display: grid;
  gap: 3px;
  padding: 10px 16px;
  border: 1px solid rgba(251, 113, 133, 0.5);
  border-radius: 8px;
  background: rgba(24, 24, 27, 0.92);
  box-shadow: 0 8px 30px rgba(0, 0, 0, 0.45);
  color: #fafafa;
  text-align: center;
}
.picker-hint small {
  color: #a1a1aa;
}
.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 22px 8px;
  border-bottom: 1px solid rgba(212, 212, 216, 0.14);
}
h1 {
  margin: 0;
  color: #fafafa;
  font-size: 21px;
  line-height: 1.2;
}
.close {
  display: grid;
  width: 28px;
  height: 28px;
  padding: 0;
  place-items: center;
  border: 1px solid rgba(212, 212, 216, 0.22);
  border-radius: 6px;
  background: #27272a;
  color: #d4d4d8;
  cursor: pointer;
  font: inherit;
  font-size: 20px;
  line-height: 1;
}
.close:hover,
.close:focus-visible {
  border-color: rgba(251, 113, 133, 0.42);
  outline: none;
  background: rgba(251, 113, 133, 0.14);
  color: #fda4af;
}
.search {
  padding: 14px;
  border-bottom: 1px solid rgba(212, 212, 216, 0.14);
}
.search label {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0 0 0 0);
  clip-path: inset(50%);
  white-space: nowrap;
}
.search input {
  width: 100%;
  padding: 10px 12px;
  border: 1px solid rgba(212, 212, 216, 0.22);
  border-radius: 7px;
  outline: none;
  background: #09090b;
  color: #fafafa;
  font: inherit;
  font-size: 13px;
}
.search input::placeholder {
  color: #71717a;
}
.search input:focus {
  border-color: #fb7185;
  box-shadow: 0 0 0 3px rgba(251, 113, 133, 0.14);
}
.actions {
  display: grid;
  flex: 1;
  align-content: start;
  gap: 8px;
  min-height: 0;
  overflow: auto;
  padding: 14px;
}
.empty {
  margin: 28px 0;
  color: #a1a1aa;
  text-align: center;
}
.filtered-count {
  margin: 5px 0 1px;
  color: #71717a;
  font-size: 10px;
  text-align: center;
}
.action {
  border: 1px solid rgba(212, 212, 216, 0.14);
  border-radius: 8px;
  background: rgba(9, 9, 11, 0.38);
}
.action-heading {
  display: flex;
  align-items: stretch;
}
.favorite {
  flex: 0 0 46px;
  border: 0;
  border-right: 1px solid rgba(212, 212, 216, 0.12);
  border-radius: 8px 0 0 8px;
  background: transparent;
  color: #71717a;
  cursor: pointer;
  font: inherit;
  font-size: 21px;
}
.favorite:hover,
.favorite:focus-visible {
  outline: none;
  background: rgba(251, 191, 36, 0.1);
  color: #fcd34d;
}
.favorite.active {
  color: #fbbf24;
}
.toggle {
  display: flex;
  width: 100%;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 14px 16px;
  border: 0;
  background: transparent;
  color: #fafafa;
  cursor: pointer;
  border-radius: 0 8px 8px 0;
  text-align: left;
}
.toggle:hover,
.toggle:focus-visible {
  background: rgba(251, 113, 133, 0.1);
  outline: none;
}
.toggle strong,
.toggle small {
  display: block;
}
.toggle strong {
  font-size: 14px;
}
.toggle small {
  margin-top: 4px;
  color: #a1a1aa;
  font-size: 12px;
  font-weight: 400;
}
.chevron {
  color: #fda4af;
  font-size: 20px;
  transition: transform 160ms ease;
}
.toggle[aria-expanded='true'] .chevron {
  transform: rotate(180deg);
}
.form {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 14px;
  padding: 16px;
  border-top: 1px solid rgba(212, 212, 216, 0.12);
  background: rgba(9, 9, 11, 0.35);
}
.field {
  display: grid;
  gap: 6px;
  color: #d4d4d8;
  font-size: 12px;
  font-weight: 650;
}
.field-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.optional-label {
  color: #71717a;
  font-size: 10px;
  font-weight: 500;
}
.offline-toggle {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 0;
  border: 0;
  background: transparent;
  color: #a1a1aa;
  cursor: pointer;
  font: inherit;
  font-size: 10px;
  font-weight: 550;
}
.offline-toggle > span {
  position: relative;
  width: 22px;
  height: 12px;
  border-radius: 999px;
  background: #3f3f46;
  transition: background 140ms ease;
}
.offline-toggle > span::after {
  position: absolute;
  top: 2px;
  left: 2px;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #a1a1aa;
  content: '';
  transition: transform 140ms ease;
}
.offline-toggle[aria-checked='true'] {
  color: #fda4af;
}
.offline-toggle[aria-checked='true'] > span {
  background: rgba(251, 113, 133, 0.45);
}
.offline-toggle[aria-checked='true'] > span::after {
  background: #fb7185;
  transform: translateX(10px);
}
.field input:not(.checkbox),
.enum-trigger {
  width: 100%;
  min-width: 0;
  padding: 9px 10px;
  border: 1px solid rgba(212, 212, 216, 0.22);
  border-radius: 6px;
  outline: none;
  background: #09090b;
  color: #fafafa;
  font: inherit;
  font-weight: 500;
}
.field input:focus,
.enum-trigger:focus {
  border-color: #fb7185;
  box-shadow: 0 0 0 3px rgba(251, 113, 133, 0.14);
}
.checkbox {
  width: 18px;
  height: 18px;
  accent-color: #fb7185;
}
.coordinate-input {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr)) auto;
  gap: 8px;
}
.coordinate-input label {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  align-items: center;
  gap: 5px;
}
.coordinate-input label > span {
  color: #71717a;
  font-size: 10px;
}
.pick-coordinate {
  padding: 0 12px;
  border: 1px solid rgba(251, 113, 133, 0.42);
  border-radius: 6px;
  background: rgba(251, 113, 133, 0.14);
  color: #ffe4e6;
  cursor: crosshair;
  font: inherit;
}
.pick-coordinate:hover,
.pick-coordinate:focus-visible {
  background: rgba(251, 113, 133, 0.24);
  outline: none;
}
.choice {
  position: relative;
}
.choice,
.full-width {
  grid-column: 1 / -1;
}
.select {
  position: relative;
}
.enum-trigger {
  display: flex;
  align-items: center;
  justify-content: space-between;
  cursor: pointer;
  text-align: left;
}
.options {
  position: absolute;
  z-index: 10;
  top: calc(100% + 5px);
  right: 0;
  left: 0;
  width: min(560px, calc(100vw - 96px));
  min-width: 100%;
  max-height: 220px;
  overflow-y: auto;
  padding: 4px;
  border: 1px solid rgba(212, 212, 216, 0.22);
  border-radius: 7px;
  background: #18181b;
  box-shadow: 0 14px 32px rgba(0, 0, 0, 0.42);
}
.options button {
  display: flex;
  width: 100%;
  align-items: center;
  gap: 10px;
  padding: 8px 9px;
  border: 0;
  border-radius: 4px;
  background: transparent;
  color: #e4e4e7;
  cursor: pointer;
  font: inherit;
  text-align: left;
  user-select: none;
}
.options button:hover,
.options button[aria-selected='true'] {
  background: rgba(251, 113, 133, 0.14);
  color: #fafafa;
}
.option-text {
  display: grid;
  flex: 1;
  min-width: 0;
  gap: 3px;
}
.option-text strong {
  overflow: hidden;
  font-weight: 650;
  text-overflow: ellipsis;
  text-transform: capitalize;
  white-space: normal;
}
.option-text small {
  overflow-wrap: anywhere;
  color: #71717a;
  font-size: 10px;
  font-weight: 500;
}
.options p {
  margin: 10px;
  color: #a1a1aa;
  font-size: 11px;
  font-weight: 500;
  text-align: center;
}
.footer {
  grid-column: 1 / -1;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 16px;
  margin-top: 2px;
}
.result {
  flex: 1;
  margin: 0;
  color: #a3e635;
  font-size: 12px;
}
.error {
  color: #f87171;
}
.execute {
  padding: 9px 16px;
  border: 1px solid rgba(251, 113, 133, 0.42);
  border-radius: 6px;
  background: rgba(251, 113, 133, 0.14);
  color: #ffe4e6;
  cursor: pointer;
  font-weight: 700;
}
.execute:hover:not(:disabled),
.execute:focus-visible {
  background: rgba(251, 113, 133, 0.24);
  outline: none;
}
.execute:disabled {
  cursor: wait;
  opacity: 0.55;
}
.roll-down-enter-active,
.roll-down-leave-active {
  transition:
    transform 220ms cubic-bezier(0.22, 1, 0.36, 1),
    opacity 160ms ease;
}
.roll-down-enter-from,
.roll-down-leave-to {
  opacity: 0;
  transform: translateY(-100%);
}
@media (prefers-reduced-motion: reduce) {
  .roll-down-enter-active,
  .roll-down-leave-active {
    transition-duration: 1ms;
  }
}
</style>
