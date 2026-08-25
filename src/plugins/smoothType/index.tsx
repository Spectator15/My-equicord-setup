/*
 * Vencord, a Discord client mod
 * Copyright (c) 2024 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";

const STYLE_ID = "vc-smoothtype";

const settings = definePluginSettings({
    transitionDelay: {
        type: OptionType.NUMBER,
        description: "Transition Delay (ms)",
        default: 60,
        onChange: () => applyCSS(),
    },
    animationType: {
        type: OptionType.SELECT,
        description: "Animation Type",
        options: [
            { label: "Ease", value: "ease", default: true },
            { label: "Linear", value: "linear" },
            { label: "Ease-in", value: "ease-in" },
            { label: "Ease-out", value: "ease-out" },
            { label: "Ease-in-out", value: "ease-in-out" },
        ],
        onChange: () => applyCSS(),
    },
});

function buildCSS(): string {
    const ms = settings.store.transitionDelay ?? 60;
    const easing = settings.store.animationType ?? "ease";
    return `
@keyframes vc-blink {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0; }
}
#vc-smoothtype-caret.is-blinking {
    animation: vc-blink 1s ease-in-out infinite;
}
#vc-smoothtype-caret {
    position: fixed;
    top: 0; left: 0;
    width: 2px;
    border-radius: 2px;
    background: white;
    pointer-events: none;
    z-index: 99999;
    display: none;
    transition: left ${ms}ms ${easing}, top ${ms}ms ${easing}, height ${ms}ms ${easing};
}
[data-slate-editor] { caret-color: transparent !important; }
`;
}

function getCaret(): HTMLDivElement | null {
    let el = document.getElementById("vc-smoothtype-caret") as HTMLDivElement | null;
    if (!el) {
        if (!document.body) return null;
        el = document.createElement("div");
        el.id = "vc-smoothtype-caret";
        document.body.appendChild(el);
    }
    return el;
}

let blinkTimer: ReturnType<typeof setTimeout> | null = null;
let initTimer: ReturnType<typeof setTimeout> | null = null;
let initialized = false;

function startBlink() { blinkTimer = null; const el = getCaret(); if (!el) return; el.classList.add("is-blinking"); }
function stopBlink() {
    const el = getCaret(); if (!el) return;
    el.classList.remove("is-blinking");
    if (blinkTimer) clearTimeout(blinkTimer);
    blinkTimer = setTimeout(startBlink, 1000);
}

function applyCaretPosition() {
    const el = getCaret();
    if (!el) return;
    if (!document.activeElement?.closest("[data-slate-editor]")) { el.style.display = "none"; return; }
    const sel = window.getSelection();
    if (!sel?.rangeCount) { el.style.display = "none"; return; }
    const range = sel.getRangeAt(0).cloneRange();
    range.collapse(false);
    const rects = range.getClientRects();
    let rect: DOMRect | null = rects.length > 0 ? rects[0] : null;
    if (!rect || rect.height === 0) {
        const node = range.startContainer;
        const parent = (node.nodeType === Node.TEXT_NODE ? node.parentElement : node) as HTMLElement | null;
        if (parent) rect = parent.getBoundingClientRect();
    }
    if (!rect || rect.height === 0) { el.style.display = "none"; return; }
    const newLeft = rect.right + "px";
    const newTop = rect.top + "px";
    if (el.style.left !== newLeft || el.style.top !== newTop) { if (el.style.display !== "none") stopBlink(); }
    el.style.display = "block";
    el.style.left = newLeft;
    el.style.top = rect.top + "px";
    el.style.height = rect.height + "px";
}

let observer: MutationObserver | null = null;
function startObserver() {
    if (observer || document.visibilityState === "hidden") return;
    observer = new MutationObserver(() => applyCaretPosition());
    observer.observe(document.body, { childList: true, subtree: true });
}
function stopObserver() { observer?.disconnect(); observer = null; }

function handleVisibilityChange() {
    if (document.visibilityState === "hidden") { stopObserver(); }
    else if (document.activeElement?.closest("[data-slate-editor]")) { startObserver(); }
}

const handlers = {
    sel:   () => applyCaretPosition(),
    focus: () => { applyCaretPosition(); if (document.activeElement?.closest("[data-slate-editor]")) startObserver(); },
    blur:  () => { const el = getCaret(); if (el) el.style.display = "none"; stopObserver(); },
    key:   () => applyCaretPosition(),
    click: () => { applyCaretPosition(); if (document.activeElement?.closest("[data-slate-editor]")) startObserver(); else stopObserver(); },
};

function startListeners() {
    document.addEventListener("selectionchange", handlers.sel);
    document.addEventListener("focusin", handlers.focus);
    document.addEventListener("focusout", handlers.blur);
    document.addEventListener("keyup", handlers.key, true);
    document.addEventListener("click", handlers.click, true);
}
function stopListeners() {
    document.removeEventListener("selectionchange", handlers.sel);
    document.removeEventListener("focusin", handlers.focus);
    document.removeEventListener("focusout", handlers.blur);
    document.removeEventListener("keyup", handlers.key, true);
    document.removeEventListener("click", handlers.click, true);
}

function applyCSS() {
    document.getElementById(STYLE_ID)?.remove();
    const s = document.createElement("style");
    s.id = STYLE_ID; s.textContent = buildCSS();
    document.head.appendChild(s);
}
function removeCSS() { document.getElementById(STYLE_ID)?.remove(); }

export default definePlugin({
    name: "SmoothType",
    enabledByDefault: true,
    description: "Smooth animated caret for the Discord message input.",
    authors: [{ name: "danish", id: 0n }],
    settings,
    start() {
        const init = () => {
            initTimer = null;
            if (!document.body) { initTimer = setTimeout(init, 100); return; }
            if (initialized) return;
            initialized = true;
            applyCSS();
            getCaret();
            if (document.activeElement?.closest("[data-slate-editor]")) startObserver();
            startListeners();
            document.addEventListener("visibilitychange", handleVisibilityChange);
        };
        init();
    },
    stop() {
        initialized = false;
        if (initTimer) { clearTimeout(initTimer); initTimer = null; }
        document.removeEventListener("visibilitychange", handleVisibilityChange);
        stopObserver(); stopListeners(); removeCSS();
        if (blinkTimer) { clearTimeout(blinkTimer); blinkTimer = null; }
        document.getElementById("vc-smoothtype-caret")?.remove();
    },
});
