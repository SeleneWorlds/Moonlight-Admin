import { createApp } from 'vue';
import App from './App.vue';
import { createMockSeleneUiApi, seleneKey, type SeleneUiApi } from './selene';

export function mount(root: ParentNode, selene: SeleneUiApi): () => void {
  const target = root.querySelector('#moonlight-admin');
  if (!(target instanceof HTMLElement)) {
    throw new Error('Missing Moonlight Admin mount element.');
  }

  const app = createApp(App);
  app.provide(seleneKey, selene);
  app.mount(target);
  return () => app.unmount();
}

if (import.meta.env.DEV && document.querySelector('#moonlight-admin')) {
  mount(document, createMockSeleneUiApi());
}
