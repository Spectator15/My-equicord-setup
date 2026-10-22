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
const CARET_ID = "vc-smoothtype-caret";
const EDITOR_SELECTOR = "[data-slate-editor]";

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

// The caret moves with transform so the animation runs on the compositor instead of re-laying out the page.
// Themes can recolor it with --smoothtype-caret.
function buildCSS(): string {
    const ms = settings.store.transitionDelay ?? 60;
    const easing = settings.store.animationType ?? "ease";
    return `
@keyframes vc-blink {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0; }
}
#${CARET_ID}.is-blinking {
    animation: vc-blink 1s ease-in-out infinite;
}
#${CARET_ID} {
    position: fixed;
    top: 0; left: 0;
    width: 2px;
    border-radius: 2px;
    background: var(--smoothtype-caret, white);
    pointer-events: none;
    z-index: 99999;
    display: none;
    will-change: transform;
    transition: transform ${ms}ms ${easing}, height ${ms}ms ${easing};
}
${EDITOR_SELECTOR} { caret-color: transparent !important; }
`;
}

let caret: HTMLDivElement | null = null;
let editor: HTMLElement | null = null;
let frame = 0;
let lastX = NaN, lastY = NaN, lastHeight = NaN;
let mutationObserver: MutationObserver | null = null;
let resizeObserver: ResizeObserver | null = null;
let blinkTimer: ReturnType<typeof setTimeout> | null = null;
let syncTimer: ReturnType<typeof setTimeout> | null = null;
let initTimer: ReturnType<typeof setTimeout> | null = null;
let initialized = false;

function getCaret(): HTMLDivElement | null {
    if (caret?.isConnected) return caret;
    if (!document.body) return null;
    caret = document.getElementById(CARET_ID) as HTMLDivElement | null;
    if (!caret) {
        caret = document.createElement("div");
        caret.id = CARET_ID;
        document.body.appendChild(caret);
    }
    return caret;
}

function hideCaret() {
    if (caret) caret.style.display = "none";
    lastX = lastY = lastHeight = NaN;
}

function startBlink() { blinkTimer = null; caret?.classList.add("is-blinking"); }
function stopBlink() {
    caret?.classList.remove("is-blinking");
    if (blinkTimer) clearTimeout(blinkTimer);
    blinkTimer = setTimeout(startBlink, 1000);
}

// Coalesce every trigger into one layout read per frame, right before the browser paints anyway.
function scheduleUpdate() {
    if (editor && !frame) frame = requestAnimationFrame(updateCaret);
}

function updateCaret() {
    frame = 0;
    const el = getCaret();
    if (!el) return;
    if (!editor?.isConnected || document.activeElement?.closest(EDITOR_SELECTOR) !== editor) { hideCaret(); return; }
    const sel = window.getSelection();
    if (!sel?.rangeCount) { hideCaret(); return; }
    const range = sel.getRangeAt(0).cloneRange();
    range.collapse(false);
    let rect: DOMRect | null = range.getClientRects()[0] ?? null;
    if (!rect || rect.height === 0) {
        const node = range.startContainer;
        const parent = (node.nodeType === Node.TEXT_NODE ? node.parentElement : node) as HTMLElement | null;
        rect = parent?.getBoundingClientRect() ?? null;
    }
    if (!rect || rect.height === 0) { hideCaret(); return; }
    const x = rect.right, y = rect.top, height = rect.height;
    if (x === lastX && y === lastY && height === lastHeight) return;
    lastX = x; lastY = y; lastHeight = height;

    const wasHidden = el.style.display === "none" || !el.style.display;
    // Jump straight to the caret when it first appears instead of sliding in from its old spot
    if (wasHidden) el.style.transition = "none";
    el.style.display = "block";
    el.style.transform = `translate(${x}px, ${y}px)`;
    el.style.height = height + "px";
    if (wasHidden) { void el.offsetWidth; el.style.transition = ""; }
    stopBlink();
}

// Watch only the focused editor, not the whole app, so channel loads and pastes elsewhere cost nothing
function attach(next: HTMLElement | null) {
    if (next === editor) { scheduleUpdate(); return; }
    detach();
    if (!next) return;
    editor = next;
    mutationObserver = new MutationObserver(scheduleUpdate);
    mutationObserver.observe(next, { childList: true, subtree: true, characterData: true });
    resizeObserver = new ResizeObserver(scheduleUpdate);
    resizeObserver.observe(next);
    const box = next.closest("form");
    if (box) resizeObserver.observe(box);
    scheduleUpdate();
}

function detach() {
    mutationObserver?.disconnect(); mutationObserver = null;
    resizeObserver?.disconnect(); resizeObserver = null;
    editor = null;
    if (frame) { cancelAnimationFrame(frame); frame = 0; }
    hideCaret();
}

function syncEditor() {
    syncTimer = null;
    attach(document.hasFocus() ? document.activeElement?.closest<HTMLElement>(EDITOR_SELECTOR) ?? null : null);
}

const handlers = {
    focusIn: () => syncEditor(),
    // Focus has not landed anywhere yet during focusout, so check once it has
    focusOut: () => { if (!syncTimer) syncTimer = setTimeout(syncEditor, 0); },
    selection: () => scheduleUpdate(),
    // Long messages scroll inside the chat bar
    scroll: (e: Event) => { if (editor && (e.target as Node | null)?.contains?.(editor)) scheduleUpdate(); },
    resize: () => scheduleUpdate(),
};

function startListeners() {
    document.addEventListener("focusin", handlers.focusIn);
    document.addEventListener("focusout", handlers.focusOut);
    document.addEventListener("selectionchange", handlers.selection);
    document.addEventListener("scroll", handlers.scroll, true);
    window.addEventListener("resize", handlers.resize);
    window.addEventListener("focus", handlers.focusIn);
    window.addEventListener("blur", handlers.focusIn);
}
function stopListeners() {
    document.removeEventListener("focusin", handlers.focusIn);
    document.removeEventListener("focusout", handlers.focusOut);
    document.removeEventListener("selectionchange", handlers.selection);
    document.removeEventListener("scroll", handlers.scroll, true);
    window.removeEventListener("resize", handlers.resize);
    window.removeEventListener("focus", handlers.focusIn);
    window.removeEventListener("blur", handlers.focusIn);
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
            startListeners();
            syncEditor();
        };
        init();
    },
    stop() {
        initialized = false;
        if (initTimer) { clearTimeout(initTimer); initTimer = null; }
        if (syncTimer) { clearTimeout(syncTimer); syncTimer = null; }
        stopListeners();
        detach();
        removeCSS();
        if (blinkTimer) { clearTimeout(blinkTimer); blinkTimer = null; }
        caret?.remove(); caret = null;
        document.getElementById(CARET_ID)?.remove();
    },
});
