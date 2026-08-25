/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy } from "@webpack";
import { React, UserStore, useState, useStateFromStores } from "@webpack/common";
const StreamStore = findByPropsLazy("getActiveStreamForUser", "getAllActiveStreams");
const RTCConnectionStore = findByPropsLazy("getMediaSessionId");
const StreamerModeStore = findByPropsLazy("hidePersonalInformation");
const settings = definePluginSettings({ autoStreamProof: { type: OptionType.BOOLEAN, description: "Auto-enable when streaming", default: false, onChange(v: boolean) { if (v && isStreaming()) enableStreamProof(); } } });
let clickHandler: ((e: MouseEvent) => void) | null = null; let streamProofActive = false;
const stateListeners = new Set<(active: boolean) => void>();
function notifyState() { stateListeners.forEach(listener => listener(streamProofActive)); }
function isStreaming(): boolean { try { if (StreamerModeStore?.hidePersonalInformation) return true; const u = UserStore?.getCurrentUser?.(); if (!u) return false; if (StreamStore?.getActiveStreamForUser?.(u.id)) return true; const all = StreamStore?.getAllActiveStreams?.(); if (all?.length > 0 && all.find((s: any) => s.ownerId === u.id)) return true; if (RTCConnectionStore?.getMediaSessionId?.() && RTCConnectionStore?.getState?.()?.context === "stream") return true; return false; } catch { return false; } }
function handleStreamChange() { if (!settings.store.autoStreamProof) return; if (isStreaming()) enableStreamProof(); else disableStreamProof(); }
function enableStreamProof() { const changed = !streamProofActive; streamProofActive = true; document.body.classList.add("stream-proof-enabled"); if (!clickHandler) { clickHandler = (e: MouseEvent) => { const t = e.target as HTMLElement | null; if (!t) return; const el = t.closest("[class*=\"messageContent_\"],[class*=\"markup_\"],[class*=\"imageWrapper_\"],[class*=\"embedWrapper_\"],[class*=\"attachment_\"],[class*=\"stickerAsset_\"]"); if (el && !el.classList.contains("stream-proof-revealed")) { el.classList.add("stream-proof-revealed"); e.preventDefault(); e.stopPropagation(); } }; document.addEventListener("click", clickHandler as any, true); } if (changed) notifyState(); }
function disableStreamProof() { const changed = streamProofActive; streamProofActive = false; document.body.classList.remove("stream-proof-enabled"); if (clickHandler) { document.removeEventListener("click", clickHandler as any, true); clickHandler = null; } document.querySelectorAll(".stream-proof-revealed").forEach(el => el.classList.remove("stream-proof-revealed")); if (changed) notifyState(); }
function EyeIcon() { return <svg aria-hidden="true" role="img" xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" viewBox="0 0 24 24"><path fill="currentColor" d="M12 5C5.648 5 1 12 1 12s4.648 7 11 7 11-7 11-7-4.648-7-11-7Zm0 12a5 5 0 1 1 0-10 5 5 0 0 1 0 10Zm0-8a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z" /></svg>; }
function EyeSlashIcon() { return <svg aria-hidden="true" role="img" xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" viewBox="0 0 24 24"><path fill="currentColor" d="M2.22 2.22a.75.75 0 0 1 1.06 0l18.5 18.5a.75.75 0 1 1-1.06 1.06l-3.56-3.56A11.18 11.18 0 0 1 12 19C5.648 19 1 12 1 12s1.81-2.73 4.69-4.95L2.22 3.28a.75.75 0 0 1 0-1.06ZM12 5c1.92 0 3.7.52 5.25 1.37l-1.5 1.5A8.87 8.87 0 0 0 20.93 12a9.57 9.57 0 0 1-3.37 3.44l1.5 1.5C21.42 15.2 23 12 23 12s-4.648-7-11-7Z" /></svg>; }
const StreamProofButton: ChatBarButtonFactory = ({ isMainChat }) => {
    useStateFromStores([StreamerModeStore, StreamStore, RTCConnectionStore], () => isStreaming());
    const [active, setActive] = useState(streamProofActive);
    React.useEffect(() => { stateListeners.add(setActive); return () => { stateListeners.delete(setActive); }; }, []);
    if (!isMainChat) return null;
    function toggle() { if (streamProofActive) disableStreamProof(); else enableStreamProof(); }
    return <ChatBarButton tooltip={active ? "StreamProof: ON (click to disable)" : "StreamProof: OFF (click to enable)"} onClick={toggle}><span style={{ color: active ? "var(--status-danger)" : "currentColor" }}>{active ? <EyeSlashIcon /> : <EyeIcon />}</span></ChatBarButton>;
};
export default definePlugin({
    name: "StreamProof", description: "Blurs Discord content while streaming. Click blurred content to reveal.", authors: [{ name: "TheArmagan", id: 0n }], dependencies: ["ChatInputButtonAPI"], enabledByDefault: true, settings,
    chatBarButton: { icon: EyeSlashIcon, render: StreamProofButton },
    flux: { STREAM_START() { handleStreamChange(); }, STREAM_STOP() { handleStreamChange(); }, STREAM_CREATE() { handleStreamChange(); }, STREAM_DELETE() { handleStreamChange(); }, STREAMER_MODE_UPDATE() { handleStreamChange(); }, RTC_CONNECTION_STATE() { handleStreamChange(); } },
    start() { document.getElementById("stream-proof-styles")?.remove(); const s = document.createElement("style"); s.id = "stream-proof-styles"; s.textContent = ".stream-proof-enabled [class*=\"messageContent_\"],.stream-proof-enabled [class*=\"markup_\"],.stream-proof-enabled [class*=\"imageWrapper_\"],.stream-proof-enabled [class*=\"embedWrapper_\"],.stream-proof-enabled [class*=\"attachment_\"],.stream-proof-enabled [class*=\"stickerAsset_\"]{filter:blur(12px);transition:filter 0.2s ease;cursor:pointer}.stream-proof-enabled .stream-proof-revealed{filter:none!important;cursor:unset!important}"; document.head.appendChild(s); if (settings.store.autoStreamProof && isStreaming()) enableStreamProof(); },
    stop() { document.getElementById("stream-proof-styles")?.remove(); disableStreamProof(); stateListeners.clear(); }
});
