window.__ModuleLoader__.load({ id: "dsh-android-patch", factory: (require) => {
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.apply = apply;

/**
 * APK 补丁层客户端（宿主 WebView 环境特有问题的收纳处；dsh-web-mobile 负责通用窄屏化，
 * 这里只补 Android/WebView 差异。任何一条规则生效前都应有真机证据，禁止盲改样式。）
 */
function apply(ctx) {
	try {
		installKeyboardInset();
		installViewportFitGuard();
	} catch (error) {
		console.warn("[dsh-android-patch] apply failed", error);
	}
}

/**
 * 软键盘弹出时 visualViewport 收缩而 layout viewport 不动：输入框可能被顶出可视区、
 * 页面整体缩放错位。把键盘占位高度写进 --dsh-keyboard-inset 并挂 body 类，
 * 具体消费规则待真机取证后逐条添加（勿凭空写选择器）。
 */
function installKeyboardInset() {
	const vv = window.visualViewport;
	if (!vv) return;
	const style = document.createElement("style");
	style.textContent = [
		":root{--dsh-keyboard-inset:0px;--dsh-vvh:100vh}",
		// TODO(真机): 键盘弹出时消费 --dsh-keyboard-inset 的具体规则（依赖 device-check 抓到的 DOM 结构）
	].join("\n");
	document.head.append(style);
	let lastHeight = vv.height;
	const update = () => {
		const inset = Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop));
		document.documentElement.style.setProperty("--dsh-keyboard-inset", (inset > 80 ? inset : 0) + "px");
		document.documentElement.style.setProperty("--dsh-vvh", Math.round(vv.height) + "px");
		document.body.classList.toggle("dsh-android-keyboard", inset > 80);
		lastHeight = vv.height;
	};
	vv.addEventListener("resize", update);
	vv.addEventListener("scroll", update);
	update();
}

/** 安全区 viewport-fit=cover：内核改版时会重写 meta（dsh-web-mobile #46 同样在抢），这里只做缺失兜底。 */
function installViewportFitGuard() {
	const applyGuard = () => {
		let meta = document.querySelector('meta[name="viewport"]');
		if (!meta) {
			meta = document.createElement("meta");
			meta.name = "viewport";
			document.head.append(meta);
		}
		if (!meta.content.includes("viewport-fit")) {
			meta.content = meta.content + ", viewport-fit=cover";
		}
	};
	applyGuard();
	new MutationObserver(applyGuard).observe(document.head, { childList: true });
}

/* TODO(真机取证): dsh-web-mobile issue #202 —— rc.2 内核顶栏 grid 化后 header>:first-child
 * 指向 headerLeading、座位预留打空。验收时抓 header DOM 快照，把修正规则加进
 * installKeyboardInset 的 style 里（有证据才写）。 */
return exports; } });
