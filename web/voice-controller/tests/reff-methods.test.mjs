// REFF 清单是网页方法调用的白名单；确保服务注册方法全部声明，避免运行时“方法未声明”。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';

const root = new URL('../../../', import.meta.url);
const manifest = JSON.parse(readFileSync(new URL('reframework/reff/plugins/voice-controller/manifest.json', root), 'utf8'));
const service = readFileSync(new URL('reframework/autorun/VoiceController/VoiceControllerREFF.lua', root), 'utf8');
const methods = [...service.matchAll(/\["(voice-controller\.[a-z0-9-]+)"\]\s*=/g)].map(match => match[1]);

test('REFF manifest 与 Lua 服务声明相同的方法', () => {
  assert.deepEqual([...manifest.methods].sort(), methods.sort());
});
