/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import definePlugin from "@utils/types";
import { findByPropsLazy } from "@webpack";
import { FluxDispatcher, React, UserStore, useState,VoiceStateStore } from "@webpack/common";

const ChannelActions = findByPropsLazy("selectVoiceChannel", "disconnect");

// Module-level state (persists across renders)
let antiMoveEnabled = false;
let targetChannelId: string | null = null;
let returnTimer: ReturnType<typeof setTimeout> | null = null;

function returnToTargetChannel() {
    if (!targetChannelId) return;
    if (returnTimer) clearTimeout(returnTimer);
    returnTimer = setTimeout(() => {
        returnTimer = null;
        try { if (targetChannelId) ChannelActions?.selectVoiceChannel?.(targetChannelId); } catch {}
    }, 500);
}

function onVoiceStateUpdate({ voiceStates }: { voiceStates: any[]; }) {
    if (!antiMoveEnabled || !targetChannelId) return;
    const currentUser = UserStore.getCurrentUser();
    if (!currentUser) return;
    const myState = voiceStates.find(s => s.userId === currentUser.id);
    if (!myState) return;
    // If moved to a different channel or disconnected, snap back
    if (myState.channelId && myState.channelId !== targetChannelId) {
        returnToTargetChannel();
    } else if (!myState.channelId) {
        // Disconnected - rejoin
        returnToTargetChannel();
    }
}

// Listeners set so the button component can react to module-level state changes
const stateListeners = new Set<(enabled: boolean) => void>();
function notifyStateChange(enabled: boolean) { stateListeners.forEach(fn => fn(enabled)); }

const AntiMoveButton: ChatBarButtonFactory = ({ isMainChat }) => {
    const [enabled, setEnabled] = useState(antiMoveEnabled);

    React.useEffect(() => {
        const listener = (e: boolean) => setEnabled(e);
        stateListeners.add(listener);
        return () => { stateListeners.delete(listener); };
    }, []);

    if (!isMainChat) return null;

    function toggle() {
        antiMoveEnabled = !antiMoveEnabled;
        if (antiMoveEnabled) {
            // Lock to current voice channel
            try {
                const me = UserStore.getCurrentUser();
                if (me) {
                    const vs = VoiceStateStore?.getVoiceStateForUser?.(me.id);
                    targetChannelId = vs?.channelId ?? null;
                }
            } catch {}
        } else {
            targetChannelId = null;
        }
        notifyStateChange(antiMoveEnabled);
    }

    const color = enabled ? "#43b581" : "currentColor";
    const tooltip = enabled
        ? `AntiMove: ON${targetChannelId ? " (locked)" : " (join a VC first)"} - click to disable`
        : "AntiMove: OFF - click to enable (join a VC first)";

    return (
        <ChatBarButton tooltip={tooltip} onClick={toggle}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                <circle cx="12" cy="12" r="9" stroke={color} strokeWidth="2" />
                {enabled
                    ? <path fill={color} d="M9 12l2 2 4-4" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                    : <path fill={color} d="M8 8l8 8M16 8l-8 8" stroke={color} strokeWidth="2" strokeLinecap="round" />
                }
            </svg>
        </ChatBarButton>
    );
};

export default definePlugin({
    name: "AntiMoveDeco",
    description: "Prevents being moved or disconnected from a voice channel. Toggle via chat bar button.",
    authors: [{ name: "Nightcord", id: 0n }],
    enabledByDefault: true,
    dependencies: ["ChatInputButtonAPI"],
    chatBarButton: { icon: () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2" /></svg>, render: AntiMoveButton },
    start() { FluxDispatcher.subscribe("VOICE_STATE_UPDATES", onVoiceStateUpdate); },
    stop() { FluxDispatcher.unsubscribe("VOICE_STATE_UPDATES", onVoiceStateUpdate); if (returnTimer) { clearTimeout(returnTimer); returnTimer = null; } antiMoveEnabled = false; targetChannelId = null; notifyStateChange(false); }
});
