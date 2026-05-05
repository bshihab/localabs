// Reexport the native module. On web, it will be resolved to DummyModule.web.ts
// and on native platforms to DummyModule.ts
export { default } from './src/DummyModule';
export { default as DummyView } from './src/DummyView';
export * from  './src/Dummy.types';
