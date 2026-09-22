import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {parse, compileScript} from 'vue/compiler-sfc';
import {createSSRApp} from 'vue';
import {renderToString} from 'vue/server-renderer';
import ts from 'typescript';

// 编译并实际渲染统计组件，覆盖 REFF 将空 Lua 表编码为 null 的协议边界；仅替换翻译文本。
const filename = new URL('../src/components/StatusPanel.vue', import.meta.url);
const source = readFileSync(filename, 'utf8').replace(
  "import {useI18n} from 'vue-i18n';",
  'const useI18n = () => ({t: (key: string) => key});',
);
const {descriptor} = parse(source);
const compiled = compileScript(descriptor, {id: 'status-regression', inlineTemplate: true});
const js = ts.transpileModule(compiled.content, {
  compilerOptions: {target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext},
}).outputText.replace(/from (['"])vue\1/g, `from '${import.meta.resolve('vue')}'`);
const {default: StatusPanel} = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);

const cases = [
  {name: '状态尚未返回', state: null, counts: [0, 0, 0, 0]},
  {name: '收藏为空但分组存在', state: {status: {totalCaptured: 42}, savedEvents: null,
    config: {groups: [{}], blockedSourcePrefixes: null}}, counts: [42, 0, 1, 0]},
  {name: '分组为空但收藏存在', state: {status: {totalCaptured: 7}, savedEvents: [{}],
    config: {groups: null, blockedSourcePrefixes: ['EnvPos']}}, counts: [7, 1, 0, 1]},
  {name: '所有列表为空', state: {status: {totalCaptured: 0}, savedEvents: null,
    config: {groups: null, blockedSourcePrefixes: null}}, counts: [0, 0, 0, 0]},
  {name: '正常非空列表', state: {status: {totalCaptured: 99}, savedEvents: [{}, {}],
    config: {groups: [{}], blockedSourcePrefixes: ['a', 'b']}}, counts: [99, 2, 1, 2]},
];

for (const {name, state, counts} of cases) {
  test(name, async () => {
    const app = createSSRApp(StatusPanel, {state, loading: false, error: ''});
    app.component('el-alert', {render: () => null});
    const errors = [];
    app.config.errorHandler = error => errors.push(error);
    const html = await renderToString(app);
    assert.deepEqual(errors, [], '统计组件不得产生渲染异常');
    assert.deepEqual([...html.matchAll(/<strong[^>]*>(\d+)<\/strong>/g)].map(match => Number(match[1])), counts);
  });
}
