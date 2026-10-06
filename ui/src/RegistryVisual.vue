<script setup lang="ts">
import { onUnmounted, ref, watch } from 'vue';
import { useSelene, type VisualDefinition, type VisualFrameDefinition } from './selene';

interface RenderLayer {
  texture: string;
  flipX: boolean;
  flipY: boolean;
}

const props = defineProps<{ identifier: string }>();
const selene = useSelene();
const layers = ref<RenderLayer[]>([]);
let generation = 0;

function firstFrame(definition: VisualDefinition): VisualFrameDefinition | undefined {
  const frame = definition.frames?.[0];
  if (frame) {
    return typeof frame === 'string' ? { ...definition, texture: frame } : { ...definition, ...frame };
  }
  const texture = definition.textures?.[0];
  if (texture) {
    return { ...definition, texture };
  }
  if (definition.texture) {
    return definition;
  }
  const animations = definition.animations ?? {};
  const preferredAnimation = ['stationary/west', 'idle/west']
    .map((name) => animations[name])
    .find((animation) => animation !== undefined);
  const westAnimation = Object.entries(animations).find(([name]) => name.toLocaleLowerCase().endsWith('/west'))?.[1];
  const animation = preferredAnimation ?? westAnimation ?? Object.values(animations)[0];
  if (!animation) {
    return undefined;
  }
  const animationFrame = animation.frames?.[0];
  if (animationFrame) {
    return typeof animationFrame === 'string'
      ? { ...definition, ...animation, texture: animationFrame }
      : { ...definition, ...animation, ...animationFrame };
  }
  return animation.textures?.[0] ? { ...definition, ...animation, texture: animation.textures[0] } : undefined;
}

async function load(): Promise<void> {
  const current = ++generation;
  layers.value = [];
  try {
    const definition = await selene.visuals.getDefinition(props.identifier);
    const definitions = definition.layers?.length ? definition.layers : [definition];
    const resolved = await Promise.all(
      definitions.map(async (part): Promise<RenderLayer | undefined> => {
        const frame = firstFrame(part);
        if (!frame?.texture) {
          return undefined;
        }
        return {
          texture: await selene.resolveAsset(frame.texture),
          flipX: frame.flipX ?? false,
          flipY: frame.flipY ?? false,
        };
      }),
    );
    if (current === generation) {
      layers.value = resolved.filter((layer): layer is RenderLayer => layer !== undefined);
    }
  } catch (error) {
    console.warn('[Moonlight Admin] Could not load registry visual', props.identifier, error);
  }
}

watch(
  () => props.identifier,
  () => void load(),
  { immediate: true },
);
onUnmounted(() => generation++);
</script>

<template>
  <span class="registry-visual" aria-hidden="true">
    <img
      v-for="(layer, index) in layers"
      :key="`${index}:${layer.texture}`"
      :src="layer.texture"
      alt=""
      :style="{ transform: `translate(-50%, -50%) scale(${layer.flipX ? -1 : 1}, ${layer.flipY ? -1 : 1})` }"
    />
  </span>
</template>

<style scoped>
.registry-visual {
  position: relative;
  display: block;
  flex: 0 0 44px;
  width: 44px;
  height: 44px;
  overflow: hidden;
  border-radius: 5px;
  background: rgba(9, 9, 11, 0.52);
  pointer-events: none;
}
.registry-visual img {
  position: absolute;
  top: 50%;
  left: 50%;
  display: block;
  max-width: 42px;
  max-height: 42px;
  object-fit: contain;
  image-rendering: auto;
  user-select: none;
}
</style>
