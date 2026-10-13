/**
 * 宿主侧入口：本插件只有浏览器半边（形状对齐 dsh-web-mobile 的组合包约定）。
 * cordis 按 `export const name` + `export function apply(ctx)` 识别插件定义，
 * `export default {}` 会被判为无效入口（failed to import）。
 */
export const name = 'dsh-android-patch';

export function apply() {}
