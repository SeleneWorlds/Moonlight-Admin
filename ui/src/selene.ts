// TODO This should later be moved into a selene-ui package that can be used by other bundles too
import { inject, type InjectionKey } from 'vue';

export type ClientNetworkPayload = Record<string, unknown>;
export interface Coordinate {
  x: number;
  y: number;
  z: number;
}
export interface MapTile extends Coordinate {
  visualMetadata: Readonly<Record<string, unknown>>;
}
export interface WorldEntity {
  networkId: number;
  coordinate: Coordinate;
  tags: readonly string[];
  visual?: string;
  draggable: boolean;
  getComponent(name: string): unknown;
}
export interface SelenePointerEvent {
  clientX: number;
  clientY: number;
  button: number;
  shiftKey: boolean;
  coordinate: Coordinate;
}

export interface SeleneUiApi {
  readonly apiVersion: number;
  readonly resolveAsset: (path: string) => Promise<string>;
  readonly visuals: {
    getDefinition(identifier: string): Promise<VisualDefinition>;
  };
  readonly storage: {
    load(key: string): Promise<string | null>;
    save(key: string, value: string): Promise<void>;
  };
  readonly input: {
    captureKeys(...keys: string[]): () => void;
    captureText(): () => void;
    passThroughKeys(...keys: string[]): () => void;
    isPassthroughKey(key: string): boolean;
    hasEditableFocus(): boolean;
    onPointerDown(callback: (event: SelenePointerEvent) => void): () => void;
    onPointerUp(callback: (event: SelenePointerEvent) => void): () => void;
  };
  readonly network: {
    sendToServer(payloadId: string, payload?: ClientNetworkPayload): void;
    onPayload(payloadId: string, callback: (payload: ClientNetworkPayload) => void): () => void;
    onConnected(callback: () => void): () => void;
  };
  readonly world: {
    getCameraCoordinate(): Coordinate;
    getControlledEntity(): WorldEntity | null;
    getMapTiles(coordinate?: Coordinate, width?: number, height?: number): MapTile[];
    projectCoordinate(coordinate: Coordinate): { x: number; y: number };
    getEntitiesAt(coordinate: Coordinate): Promise<WorldEntity[]>;
    projectEntity(networkId: number): { x: number; y: number } | null;
    onCameraCoordinateChanged(callback: (coordinate: Coordinate) => void): () => void;
    onMapChanged(callback: (coordinate: Coordinate, width: number, height: number) => void): () => void;
  };
}

export const seleneKey: InjectionKey<SeleneUiApi> = Symbol('selene-api');

export const useSelene = (): SeleneUiApi => {
  const selene = inject(seleneKey);
  if (!selene) {
    throw new Error('Selene API was not provided.');
  }
  return selene;
};

export interface VisualFrameDefinition {
  texture?: string;
  duration?: number;
  offsetX?: number;
  offsetY?: number;
  flipX?: boolean;
  flipY?: boolean;
}

export interface VisualDefinition extends VisualFrameDefinition {
  type?: string;
  textures?: string[];
  frames?: Array<string | VisualFrameDefinition>;
  animations?: Record<
    string,
    VisualFrameDefinition & { textures?: string[]; frames?: Array<string | VisualFrameDefinition> }
  >;
  layers?: VisualDefinition[];
  instanced?: boolean;
}

export const createMockSeleneUiApi = (): SeleneUiApi => {
  const passthroughKeys = new Map<string, number>();

  return {
    apiVersion: 8,
    resolveAsset: async (path) => `/${path.replace(/^client\/ui\/dist\//, '')}`,
    visuals: {
      getDefinition: async (identifier) => {
        const response = await fetch('/client/registries/selene:visuals');
        const snapshot = (await response.json()) as { entries?: Record<string, VisualDefinition> };
        const definition = snapshot.entries?.[identifier];
        if (!definition) {
          throw new Error(`Visual not found: ${identifier}`);
        }
        return definition;
      },
    },
    storage: {
      load: async (key) => window.localStorage.getItem(`selene.bundle.dev.${key}`),
      save: async (key, value) => window.localStorage.setItem(`selene.bundle.dev.${key}`, value),
    },
    input: {
      captureKeys: () => () => undefined,
      captureText: () => () => undefined,
      passThroughKeys: (...keys) => {
        const uniqueKeys = new Set(keys);
        uniqueKeys.forEach((key) => passthroughKeys.set(key, (passthroughKeys.get(key) ?? 0) + 1));
        let active = true;
        return () => {
          if (!active) {
            return;
          }
          active = false;
          uniqueKeys.forEach((key) => {
            const count = passthroughKeys.get(key)! - 1;
            if (count) {
              passthroughKeys.set(key, count);
            } else {
              passthroughKeys.delete(key);
            }
          });
        };
      },
      isPassthroughKey: (key) => passthroughKeys.has(key),
      hasEditableFocus: () => {
        const active = document.activeElement;
        return (
          active instanceof HTMLInputElement ||
          active instanceof HTMLTextAreaElement ||
          active instanceof HTMLSelectElement ||
          (active instanceof HTMLElement && active.isContentEditable)
        );
      },
      onPointerDown: () => () => undefined,
      onPointerUp: () => () => undefined,
    },
    network: {
      onConnected: (callback) => {
        callback();
        return () => undefined;
      },
      sendToServer: (payloadId, payload) => console.info('[Selene UI]', payloadId, payload),
      onPayload: () => () => undefined,
    },
    world: {
      getCameraCoordinate: () => ({ x: 0, y: 0, z: 0 }),
      getControlledEntity: () => null,
      getMapTiles: () => [],
      projectCoordinate: () => ({ x: 0, y: 0 }),
      getEntitiesAt: async () => [],
      projectEntity: () => null,
      onCameraCoordinateChanged: () => () => undefined,
      onMapChanged: () => () => undefined,
    },
  };
};
