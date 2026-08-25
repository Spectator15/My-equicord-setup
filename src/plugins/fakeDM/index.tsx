/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Modified for My Equicord Setup by Spectator15, 2026-08-15.
 * Original copyright and authorship remain with the respective upstream contributors.
 */

import "./styles.css";

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import * as DataStore from "@api/DataStore";
import { Logger } from "@utils/Logger";
import definePlugin from "@utils/types";
import { ChannelStore, FluxDispatcher, IconUtils, React, ReactDOM, SelectedChannelStore, UserStore } from "@webpack/common";

let _idCounter = 0;
function uniqueSnowflake(date: Date): string { const offset = _idCounter++ % 4096; const ms = Math.max(0, date.getTime() - 1420070400000); return ((BigInt(ms) << 22n) | BigInt(offset)).toString(); }
function randomSeconds(date: Date): Date { return new Date(date.getTime() + (1 + Math.floor(Math.random() * 59)) * 1000); }

const STORAGE_KEY = "nightcord_fakedm_fakes";
const MAX_PERSISTED = 250;
const logger = new Logger("FakeDM");
type PersistedFake = { type: "message"; channelId: string; authorId: string; content: string; timestamp: string; snowflakeId: string; } | { type: "call"; channelId: string; callerId: string; otherId: string; missed: boolean; durationSec: number; timestamp: string; endedTimestamp: string | null; snowflakeId: string; };
let persistedFakes: PersistedFake[] = [];
let persistenceLoaded = false;
let persistencePromise: Promise<void> | null = null;
async function loadPersisted() {
    if (persistenceLoaded) return;
    if (persistencePromise) return persistencePromise;
    persistencePromise = (async () => {
        try {
            let stored = await DataStore.get<PersistedFake[]>(STORAGE_KEY);
            if (!Array.isArray(stored)) {
                const legacyRaw = localStorage.getItem(STORAGE_KEY);
                const legacy = legacyRaw ? JSON.parse(legacyRaw) : [];
                stored = Array.isArray(legacy) ? legacy : [];
                await DataStore.set(STORAGE_KEY, stored.slice(-MAX_PERSISTED));
                localStorage.removeItem(STORAGE_KEY);
            }
            persistedFakes = stored.slice(-MAX_PERSISTED);
        } catch (error) {
            logger.error("Failed to load persisted local entries", error);
            persistedFakes = [];
        } finally {
            persistenceLoaded = true;
            persistencePromise = null;
        }
    })();
    return persistencePromise;
}
function savePersisted(fakes: PersistedFake[]) {
    persistedFakes = fakes.slice(-MAX_PERSISTED);
    void DataStore.set(STORAGE_KEY, persistedFakes).catch(error => logger.error("Failed to save local entries", error));
}

const fakeIds = new Map<string, Set<string>>();
function registerFake(channelId: string, id: string) { if (!fakeIds.has(channelId)) fakeIds.set(channelId, new Set()); fakeIds.get(channelId)!.add(id); }
function clearFakes(channelId: string): number { const ids = fakeIds.get(channelId); if (!ids?.size) return 0; let n = 0; for (const id of ids) { FluxDispatcher.dispatch({ type: "MESSAGE_DELETE", channelId, id, mlDeleted: true }); n++; } savePersisted(persistedFakes.filter(f => !(f.channelId === channelId && ids.has(f.snowflakeId)))); ids.clear(); return n; }

function avatarUrl(user: any): string { if (!user) return ""; return user.avatar ? IconUtils.getUserAvatarURL(user, false, 32) : IconUtils.getDefaultAvatarURL(user.id); }
function getCurrentDMChannel(): any | null { try { const chId = SelectedChannelStore.getChannelId(); if (!chId) return null; const ch = ChannelStore.getChannel(chId); if (!ch || (ch.type !== 1 && ch.type !== 3)) return null; return ch; } catch { return null; } }
function getOtherUser(): any | null { try { const ch = getCurrentDMChannel(); if (!ch || ch.type !== 1) return null; const me = UserStore.getCurrentUser(); const otherId = ch.recipients?.find((id: string) => id !== me?.id); return otherId ? (UserStore.getUser(otherId) ?? null) : null; } catch { return null; } }
function getChannelMembers(): any[] { try { const ch = getCurrentDMChannel(); if (!ch) return []; const me = UserStore.getCurrentUser(); const ids: string[] = ch.recipients ?? ch.rawRecipients?.map((r: any) => r.id) ?? []; const members: any[] = []; if (me) members.push(me); for (const id of ids) { if (id === me?.id) continue; const u = UserStore.getUser(id); if (u) members.push(u); } return members; } catch { return []; } }
function buildAuthor(user: any) { return { id: user.id, username: user.username, discriminator: user.discriminator ?? "0", avatar: user.avatar ?? null, public_flags: user.publicFlags ?? 0, flags: user.flags ?? 0, banner: user.banner ?? null, accent_color: null, global_name: user.globalName ?? user.username, avatar_decoration_data: null, banner_color: null }; }

function inject(channelId: string, author: any, content: string, date: Date, persistedId?: string) {
    const actualDate = persistedId ? date : randomSeconds(date); const id = persistedId ?? uniqueSnowflake(actualDate);
    FluxDispatcher.dispatch({ type: "MESSAGE_CREATE", channelId, message: { attachments: [], components: [], embeds: [], mention_roles: [], mentions: [], author: buildAuthor(author), channel_id: channelId, content, edited_timestamp: null, flags: 0, id, mention_everyone: false, nonce: id, pinned: false, timestamp: actualDate.toISOString(), tts: false, type: 0 }, optimistic: false, isPushNotification: false });
    registerFake(channelId, id);
    if (!persistedId) savePersisted([...persistedFakes, { type: "message", channelId, authorId: author.id, content, timestamp: actualDate.toISOString(), snowflakeId: id }]);
}

function injectCall(channelId: string, caller: any, other: any, missed: boolean, durationSec: number, date: Date, persistedId?: string, persistedEndedTs?: string | null) {
    const actualDate = persistedId ? date : randomSeconds(date); const id = persistedId ?? uniqueSnowflake(actualDate);
    const endedDate = missed ? actualDate : (persistedEndedTs ? new Date(persistedEndedTs) : new Date(actualDate.getTime() + durationSec * 1000));
    FluxDispatcher.dispatch({ type: "MESSAGE_CREATE", channelId, message: { attachments: [], components: [], embeds: [], mention_roles: [], mentions: [], author: buildAuthor(caller), channel_id: channelId, content: "", edited_timestamp: null, flags: 0, id, mention_everyone: false, nonce: id, pinned: false, timestamp: actualDate.toISOString(), tts: false, type: 3, call: { participants: missed ? [caller.id] : [caller.id, other.id], ended_timestamp: endedDate.toISOString(), duration: missed ? undefined : durationSec } }, optimistic: false, isPushNotification: false });
    registerFake(channelId, id);
    if (!persistedId) savePersisted([...persistedFakes, { type: "call", channelId, callerId: caller.id, otherId: other.id, missed, durationSec, timestamp: actualDate.toISOString(), endedTimestamp: endedDate.toISOString(), snowflakeId: id }]);
}

let _restoreHandler: (() => void) | null = null;
let _restoreTimer: ReturnType<typeof setTimeout> | null = null;
function scheduleRestore() {
    if (_restoreTimer) clearTimeout(_restoreTimer);
    _restoreTimer = setTimeout(() => { _restoreTimer = null; for (const f of persistedFakes) { if (f.type === "message") { const author = UserStore.getUser(f.authorId); if (author) inject(f.channelId, author, f.content, new Date(f.timestamp), f.snowflakeId); } else { const caller = UserStore.getUser(f.callerId); const other = UserStore.getUser(f.otherId); if (caller && other) injectCall(f.channelId, caller, other, f.missed, f.durationSec, new Date(f.timestamp), f.snowflakeId, f.endedTimestamp); } } }, 1200);
}

function toLocal(d: Date): string { const p = (n: number) => String(n).padStart(2, "0"); return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; }

function UserAvatar({ user }: { user: any; }) { const [err, setErr] = React.useState(false); if (!user) return null; const url = avatarUrl(user); if (err || !url) return <div className="fdm-sender-avatar fdm-sender-avatar-placeholder">{user.username?.[0]?.toUpperCase() ?? "?"}</div>; return <img src={url} className="fdm-sender-avatar" alt="" onError={() => setErr(true)} />; }
function MemberSelect({ members, value, onChange, label }: { members: any[]; value: string; onChange(id: string): void; label?: string; }) { return <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "4px 12px" }}>{label && <span className="fdm-date-label">{label}</span>}<select value={value} onChange={e => onChange(e.target.value)} style={{ flex: 1, background: "rgba(255,255,255,0.07)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 6, color: "#fff", fontSize: 13, padding: "4px 6px", cursor: "pointer" }}>{members.map(m => <option key={m.id} value={m.id} style={{ background: "#2b2d31" }}>{m.globalName || m.username}</option>)}</select></div>; }

let _portalRoot: HTMLDivElement | null = null;
function getPortalRoot(): HTMLDivElement { if (!_portalRoot || !document.body.contains(_portalRoot)) { _portalRoot = document.createElement("div"); _portalRoot.id = "fdm-portal-root"; document.body.appendChild(_portalRoot); } return _portalRoot; }

// Panel opens near the bottom center of the screen (above the chat bar)
function FakeDMPanel({ onClose }: { onClose(): void; }) {
    const me = UserStore.getCurrentUser(); const ch = getCurrentDMChannel(); const channelId = SelectedChannelStore.getChannelId();
    const isGroup = ch?.type === 3; const other = getOtherUser(); const members = getChannelMembers(); const isInDMOrGroup = !!ch;
    const [mode, setMode] = React.useState<"message" | "call">("message");
    const [senderId, setSenderId] = React.useState<string>(() => me?.id ?? "");
    const [callerId, setCallerId] = React.useState<string>(() => me?.id ?? "");
    const [callReceiverId, setCallReceiverId] = React.useState<string>(() => members.find(m => m.id !== me?.id)?.id ?? me?.id ?? "");
    const [callMissed, setCallMissed] = React.useState(false); const [callDuration, setCallDuration] = React.useState("5");
    const [text, setText] = React.useState(""); const [dateStr, setDateStr] = React.useState(() => toLocal(new Date()));
    const [status, setStatus] = React.useState<{ msg: string; ok: boolean; } | null>(null);
    const textareaRef = React.useRef<HTMLTextAreaElement>(null);
    const timers = React.useRef(new Set<ReturnType<typeof setTimeout>>());
    function schedulePanelTask(task: () => void, delay: number) { const timer = setTimeout(() => { timers.current.delete(timer); task(); }, delay); timers.current.add(timer); }
    React.useEffect(() => { schedulePanelTask(() => textareaRef.current?.focus(), 80); return () => { timers.current.forEach(timer => clearTimeout(timer)); timers.current.clear(); }; }, []);
    React.useEffect(() => { const h = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); }; document.addEventListener("keydown", h, true); return () => document.removeEventListener("keydown", h, true); }, [onClose]);
    function setMsg(msg: string, ok: boolean) { setStatus({ msg, ok }); schedulePanelTask(() => setStatus(null), 2500); }
    function send() { if (!text.trim() || !channelId) return; const author = members.find(m => m.id === senderId) ?? me; if (!author) return; const date = new Date(dateStr); if (isNaN(date.getTime())) { setMsg("Invalid Date!", false); return; } inject(channelId, author, text.trim(), date); setText(""); setMsg("Message injected", true); setDateStr(toLocal(new Date(date.getTime() + 60_000))); schedulePanelTask(() => textareaRef.current?.focus(), 10); }
    function sendCall() { if (!channelId) return; const callerUser = members.find(m => m.id === callerId); const receiverUser = members.find(m => m.id === callReceiverId); if (!callerUser || !receiverUser) return; const date = new Date(dateStr); if (isNaN(date.getTime())) { setMsg("Invalid Date!", false); return; } injectCall(channelId, callerUser, receiverUser, callMissed, callMissed ? 0 : Math.max(1, Math.round((parseFloat(callDuration) || 0) * 60)), date); setMsg(callMissed ? "Missed call injected" : "Call injected", true); setDateStr(toLocal(new Date(date.getTime() + 60_000))); }
    const meName = (me as any)?.globalName || me?.username || "Me"; const otherName = other?.globalName || other?.username || "Other";
    const SenderRow = isGroup ? <MemberSelect members={members} value={senderId} onChange={setSenderId} label="From:" /> : <div className="fdm-sender-row"><button className={`fdm-sender-btn${senderId === me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => setSenderId(me?.id ?? "")}><UserAvatar user={me} /><span className="fdm-sender-name">{meName}</span></button><button className={`fdm-sender-btn${senderId !== me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => setSenderId(other?.id ?? "")}><UserAvatar user={other} /><span className="fdm-sender-name">{otherName}</span></button></div>;
    const CallerRow = isGroup ? <><MemberSelect members={members} value={callerId} onChange={setCallerId} label="Caller:" /><MemberSelect members={members} value={callReceiverId} onChange={setCallReceiverId} label="Receiver:" /></> : <div className="fdm-sender-row"><button className={`fdm-sender-btn${callerId === me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => { setCallerId(me?.id ?? ""); setCallReceiverId(other?.id ?? ""); }}><UserAvatar user={me} /><span className="fdm-sender-name">{meName}</span></button><button className={`fdm-sender-btn${callerId !== me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => { setCallerId(other?.id ?? ""); setCallReceiverId(me?.id ?? ""); }}><UserAvatar user={other} /><span className="fdm-sender-name">{otherName}</span></button></div>;
    // Position: fixed, centered above chat bar
    const panelStyle: React.CSSProperties = { position: "fixed", left: "50%", transform: "translateX(-50%)", bottom: "80px", width: "430px", backgroundColor: "#2b2d31", border: "1px solid rgba(255,255,255,0.1)", borderRadius: "12px", boxShadow: "0 16px 48px rgba(0,0,0,0.65)", overflow: "hidden", zIndex: 1000000, display: "flex", flexDirection: "column" };
    return (<>
        <div onClick={onClose} style={{ position: "fixed", inset: 0, zIndex: 999999, backgroundColor: "rgba(0,0,0,0.4)" }} />
        <div className="fdm-panel" style={panelStyle} onClick={e => e.stopPropagation()} onMouseDown={e => e.stopPropagation()}>
            <div className="fdm-header"><span className="fdm-title">{mode === "message" ? "Fake DM" : "Fake Call"}{isGroup ? " (Group)" : ""}</span><button className="fdm-close" onClick={onClose}>x</button></div>
            <div style={{ display: "flex", gap: 6, padding: "0 12px 10px" }}>
                <button onClick={() => setMode("message")} style={{ flex: 1, padding: "5px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: mode === "message" ? "#5865f2" : "rgba(255,255,255,0.07)", color: mode === "message" ? "#fff" : "rgba(255,255,255,0.5)" }}>Message</button>
                <button onClick={() => setMode("call")} style={{ flex: 1, padding: "5px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: mode === "call" ? "#5865f2" : "rgba(255,255,255,0.07)", color: mode === "call" ? "#fff" : "rgba(255,255,255,0.5)" }}>Call</button>
            </div>
            {!isInDMOrGroup ? <div style={{ padding: "16px 14px", color: "rgba(255,255,255,0.45)", fontSize: 13, textAlign: "center" }}>Open a DM or group DM first.</div> :
            mode === "message" ? <>
                {SenderRow}
                <div className="fdm-date-row"><span className="fdm-date-label">Date:</span><input type="datetime-local" className="fdm-date-input" value={dateStr} onChange={e => setDateStr(e.target.value)} /><button className="fdm-date-now" onClick={() => setDateStr(toLocal(new Date()))}>Now</button></div>
                <div className="fdm-input-row"><textarea ref={textareaRef} className="fdm-textarea" rows={2} placeholder="Message (Enter to send)" value={text} onChange={e => setText(e.target.value)} onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }} /><div className="fdm-actions"><button className="fdm-send-btn" disabled={!text.trim()} onClick={send}>Send</button><button className="fdm-clear-btn" onClick={() => { if (!channelId) return; const n = clearFakes(channelId); setMsg(`${n} cleared`, true); }}>Clear</button></div></div>
            </> : <>
                {CallerRow}
                <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 12px" }}>
                    <button onClick={() => setCallMissed(false)} style={{ flex: 1, padding: "4px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: !callMissed ? "#3ba55c" : "rgba(255,255,255,0.07)", color: !callMissed ? "#fff" : "rgba(255,255,255,0.45)" }}>Answered</button>
                    <button onClick={() => setCallMissed(true)} style={{ flex: 1, padding: "4px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: callMissed ? "#ed4245" : "rgba(255,255,255,0.07)", color: callMissed ? "#fff" : "rgba(255,255,255,0.45)" }}>Missed</button>
                    {!callMissed && <div style={{ display: "flex", alignItems: "center", gap: 4 }}><input type="number" min="1" max="999" value={callDuration} onChange={e => setCallDuration(e.target.value)} style={{ width: 48, background: "rgba(255,255,255,0.07)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 6, color: "#fff", fontSize: 12, padding: "3px 6px", textAlign: "center" }} /><span style={{ fontSize: 11, color: "rgba(255,255,255,0.4)" }}>min</span></div>}
                </div>
                <div className="fdm-date-row"><span className="fdm-date-label">Date:</span><input type="datetime-local" className="fdm-date-input" value={dateStr} onChange={e => setDateStr(e.target.value)} /><button className="fdm-date-now" onClick={() => setDateStr(toLocal(new Date()))}>Now</button></div>
                <div className="fdm-input-row"><div className="fdm-actions"><button className="fdm-send-btn" onClick={sendCall}>Inject Call</button><button className="fdm-clear-btn" onClick={() => { if (!channelId) return; const n = clearFakes(channelId); setMsg(`${n} cleared`, true); }}>Clear</button></div></div>
            </>}
            {status && <div className={`fdm-status fdm-status-${status.ok ? "ok" : "error"}`}>{status.msg}</div>}
        </div>
    </>);
}

// FIXED: chatBarButton.render is the component slot; ChatBarButton wraps the icon inside it.
// The panel is rendered via a portal, toggled by clicking the bar button.
// No ref forwarding needed; panel is always centered above chat bar.
const FakeDMButtonIcon = () => <svg aria-hidden="true" role="img" xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" viewBox="0 0 24 24"><path fill="currentColor" d="M12 2C6.486 2 2 6.037 2 11c0 2.579 1.178 4.898 3.073 6.576L4 22l4.648-2.343C9.72 20.213 10.848 20.4 12 20.4c5.514 0 10-4.037 10-9s-4.486-9-10-9Zm1 13H7v-2h6v2Zm2-4H7v-2h8v2Z" /></svg>;

const FakeDMChatButton: ChatBarButtonFactory = ({ isMainChat }) => {
    const [open, setOpen] = React.useState(false);
    if (!isMainChat) return null;
    return <>
        <ChatBarButton tooltip="FakeDM" onClick={() => setOpen(v => !v)}>
            <FakeDMButtonIcon />
        </ChatBarButton>
        {open && ReactDOM.createPortal(<FakeDMPanel onClose={() => setOpen(false)} />, getPortalRoot())}
    </>;
};

export default definePlugin({
    name: "FakeDM", description: "Inject fake messages and calls into DMs. Only visible to you. Click the chat bar button.", authors: [{ name: "sqlu", id: 0n }], enabledByDefault: true, dependencies: ["ChatInputButtonAPI"],
    chatBarButton: { icon: FakeDMButtonIcon, render: FakeDMChatButton },
    async start() { await loadPersisted(); _restoreHandler = () => { fakeIds.clear(); scheduleRestore(); }; FluxDispatcher.subscribe("CONNECTION_OPEN", _restoreHandler); scheduleRestore(); },
    stop() { if (_restoreHandler) { FluxDispatcher.unsubscribe("CONNECTION_OPEN", _restoreHandler); _restoreHandler = null; } if (_restoreTimer) { clearTimeout(_restoreTimer); _restoreTimer = null; } _portalRoot?.remove(); _portalRoot = null; fakeIds.clear(); }
});
