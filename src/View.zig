//! How a conversation looks (plans/CHAT_PLAN.md, "The look"): the person's messages in rounded
//! bubbles on the right, the other side's on the left, notes centered and quiet. Inside a bubble:
//! markdown through the markdown plugin's inline render, code fenced the same way (so it is
//! highlighted as markdown's fences are), images fitted, file links, diffs, plans as checklists,
//! tool steps as one line each with their questions on them, and thinking behind one quiet line.
//!
//! Only what is on screen is laid out. Each message keeps its height, keyed by the width and its
//! version (`Transcript.Message.version`); one above or below the viewport is a spacer of that
//! height. Streaming text bumps one message's version, so a frame of a turn re-lays that one.
//! Scrolling is anchored to a message: at the bottom the view follows what arrives; scrolled up,
//! it keeps the message being read where it is through any reflow (the sidebar opening, the
//! window resizing, a tool's output opening).
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const api = @import("api.zig");
const Chat = @import("Chat.zig");
const Commands = @import("Commands.zig");
const Transcript = @import("Transcript.zig");

const entypo = dvui.entypo;

pub const State = struct {
    scroll: dvui.ScrollInfo = .{ .horizontal = .none },
    /// Each message's height as last laid out, by index.
    kept: std.ArrayListUnmanaged(Kept) = .empty,
    /// Stuck to the bottom: new content scrolls into view.
    follow: bool = true,
    /// The message at the top of the viewport and how far into it, when not following.
    anchor_message: u32 = 0,
    anchor_offset: f32 = 0,
    /// Where this frame put the viewport, to tell the person's scrolling from ours.
    set_y: f32 = 0,
    /// Thoughts opened, by `partKey`.
    open: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Messages there when the chat was first drawn: they are history, shown as they are. One that
    /// arrives after fades in, and its text types in (`reveal`).
    seen: ?usize = null,
    /// How many messages the chat had when it was first drawn: those never type in.
    history: ?usize = null,
    /// Messages fading in, and when each fade ends (`dvui.frameTimeNS`).
    fading: std.AutoHashMapUnmanaged(u32, i128) = .empty,
    /// How much of each arriving text block is shown, by `partKey`: it runs to catch up with what
    /// has streamed in, so text arrives smoothly rather than in the agent's bursts.
    reveal: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// The widget in the transcript that has focus: the text the person last pressed in (a
    /// paragraph, a note, a tool's output), or the scroll area after a click on empty space.
    focused: ?dvui.Id = null,
    /// A text that lost focus, whose selection goes at the top of the next frame (`beginFrame`).
    deselect: ?dvui.Id = null,
    /// `beginFrame` cleared a selection this frame.
    deselected: bool = false,

    const Kept = struct {
        version: u32 = std.math.maxInt(u32),
        width: f32 = 0,
        h: f32 = 0,
        /// The widest line of a text-only message, for a bubble that hugs short text.
        natural_version: u32 = std.math.maxInt(u32),
        natural_w: f32 = 0,
        /// Drawn last frame rather than stood in for by a spacer.
        drawn: bool = false,
    };

    pub fn contentChanged(self: *State) void {
        _ = self;
    }

    pub fn reset(self: *State, gpa: std.mem.Allocator) void {
        self.kept.clearRetainingCapacity();
        self.open.clearRetainingCapacity();
        self.fading.clearRetainingCapacity();
        self.reveal.clearRetainingCapacity();
        self.seen = null;
        self.history = null;
        _ = gpa;
        self.follow = true;
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.kept.deinit(gpa);
        self.open.deinit(gpa);
        self.fading.deinit(gpa);
        self.reveal.deinit(gpa);
    }
};

/// A part's key: what its markdown render is kept under, and what opens a thought.
fn partKey(chat_id: api.ChatId, message: usize, part: usize, salt: u8) u64 {
    var h = std.hash.Wyhash.init(chat_id);
    h.update(std.mem.asBytes(&@as(u32, @intCast(message))));
    h.update(std.mem.asBytes(&@as(u32, @intCast(part))));
    h.update(&.{salt});
    return h.final();
}

/// Forget every markdown render kept for this chat's messages (the chat is closing).
pub fn release(c: *Chat) void {
    const md = c.host.getServiceTyped(sdk.services.markdown.Api) orelse return;
    for (c.transcript.messages.items, 0..) |m, i| for (m.parts.items, 0..) |p, j| {
        if (p != .block) continue;
        switch (p.block) {
            .text => md.release(partKey(c.chat_id, i, j, 't')),
            .code => md.release(partKey(c.chat_id, i, j, 'c')),
            else => {},
        }
    };
}

const side_pad = 14;
const bubble_pad: dvui.Rect = .{ .x = 12, .y = 8, .w = 12, .h = 8 };

pub fn draw(c: *Chat) !dvui.App.Result {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();
    const live = Commands.isRegistered(c.client_id);
    // Packed from the bottom first, so a long conversation cannot push it out of the tab.
    if (live) drawInput(c) else drawUnavailable(c);
    drawTranscript(c);
    return .ok;
}

// ---- the conversation -----------------------------------------------------------------------

fn drawTranscript(c: *Chat) void {
    const st = &c.view;
    const gpa = c.gpa;
    const messages = c.transcript.messages.items;
    if (st.kept.items.len < messages.len) st.kept.appendNTimes(gpa, .{}, messages.len - st.kept.items.len) catch return;
    // What arrived since last frame fades in; what was there when the chat opened does not.
    const seen = st.seen orelse messages.len;
    if (seen < messages.len and !core.motion.off()) {
        const end = dvui.frameTimeNS() + @as(i128, core.motion.duration(fade_us)) * std.time.ns_per_us;
        for (seen..messages.len) |n| st.fading.put(gpa, @intCast(n), end) catch {};
    }
    st.seen = messages.len;
    if (st.history == null) st.history = messages.len;

    const vh = st.scroll.viewport.h;
    // Put the viewport where the reader is, before the scroll area reads it.
    if (st.follow) {
        st.scroll.viewport.y = @max(0, st.scroll.virtual_size.h - vh);
    } else if (st.anchor_message < messages.len) {
        st.scroll.viewport.y = @max(0, topOf(st, st.anchor_message) + st.anchor_offset);
    }
    st.set_y = st.scroll.viewport.y;
    const focus_before = dvui.lastFocusedIdInFrame();

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &st.scroll, .vertical_bar = .auto_overlay, .horizontal_bar = .hide }, .{ .expand = .both });
    const width = if (st.scroll.viewport.w > 0) st.scroll.viewport.w else scroll.data().contentRect().w;
    {
        var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .{ .y = 10, .h = 10 } });
        defer list.deinit();
        if (messages.len == 0) drawHint(c, width);
        var y: f32 = 10;
        const top = st.scroll.viewport.y - vh;
        const bottom = st.scroll.viewport.y + 2 * @max(vh, 1);
        for (messages, 0..) |*m, i| {
            const k = &st.kept.items[i];
            const valid = k.version == m.version and k.width == width and k.h > 0;
            if (valid and (y + k.h < top or y > bottom)) {
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = k.h }, .expand = .horizontal, .id_extra = i });
                k.drawn = false;
                y += k.h;
                continue;
            }
            // Back from being a spacer, its row has no size from last frame (dvui forgets the
            // widgets a frame did not draw) and would lay out empty for a frame, pulling everything
            // below it up by its height and back: the jitter scrolling up. It keeps its height.
            const h = drawMessage(c, i, m, width, if (valid and !k.drawn) k.h else 0);
            k.drawn = true;
            k.version = m.version;
            k.width = width;
            if (h > 0) k.h = h;
            y += k.h;
        }
        if (c.busy and !streaming(c)) drawTyping(c, width);
    }
    scroll.deinit();
    trackFocus(st, focus_before);

    // Following stops the moment the person scrolls up from where it was put (a wheel, a drag:
    // a trackpad's first step is a pixel or two, which a looser test snapped back to the bottom,
    // so scrolling up rubber-banded), and starts again only once they are back at the bottom.
    // The Output panel's rule (`OutputPanel.zig`).
    const max_y = @max(0, st.scroll.virtual_size.h - st.scroll.viewport.h);
    const anchored = !st.follow and st.anchor_message < messages.len;
    if (st.follow) {
        if (st.scroll.viewport.y + 1.0 < st.set_y) st.follow = false;
    } else st.follow = st.scroll.offsetFromMax(.vertical) < 1.0;
    if (st.follow and st.scroll.viewport.y < max_y - 0.5) dvui.refresh(null, @src(), null);
    // Where the reader is, in messages, for next frame. Scrolled up, the anchor moves only by what
    // the person scrolled. A message above it that this frame laid out at a new height (one coming
    // back into view settling its wrap) has already shifted what is on screen; finding the anchor
    // again from the viewport would keep that shift, so every such message nudged the reader and
    // scrolling up jittered. Kept as it was, next frame's `topOf` takes the new height and undoes it.
    if (anchored) {
        const kept = st.kept.items[0..messages.len];
        st.anchor_offset += st.scroll.viewport.y - st.set_y;
        while (st.anchor_offset < 0 and st.anchor_message > 0) {
            st.anchor_message -= 1;
            st.anchor_offset += kept[st.anchor_message].h;
        }
        while (st.anchor_message + 1 < kept.len and st.anchor_offset >= kept[st.anchor_message].h) {
            st.anchor_offset -= kept[st.anchor_message].h;
            st.anchor_message += 1;
        }
        return;
    }
    var y: f32 = 10;
    for (st.kept.items[0..messages.len], 0..) |k, i| {
        if (y + k.h > st.scroll.viewport.y) {
            st.anchor_message = @intCast(i);
            st.anchor_offset = st.scroll.viewport.y - y;
            break;
        }
        y += k.h;
    }
}

/// A selection is one text's (dvui selects within one text layout, and markdown lays out each
/// paragraph as its own), so the one the person made goes when they press anywhere else: in
/// another message, on empty space, in the message box, elsewhere in fizzy. dvui keeps a text's
/// selection when it loses focus, so the chat clears it, as a document's goes when you click away.
fn trackFocus(st: *State, before: dvui.Id) void {
    const now = dvui.lastFocusedIdInFrameSince(before);
    if (st.focused) |old| if (now == null or now.? != old) {
        st.deselect = old;
        dvui.refresh(null, @src(), null);
    };
    st.focused = now;
    // Told to select nothing, a text scrolls its cursor into view (dvui does for any selection
    // it is given): the reader stays where they were.
    if (st.deselected) {
        st.deselected = false;
        st.scroll.viewport.y = st.set_y;
    }
}

/// The top of a frame: tell the text that lost focus to select nothing. Events go in before any
/// widget runs, so this is the frame's start rather than where the chat draws.
pub fn beginFrame(c: *Chat) void {
    const id = c.view.deselect orelse return;
    c.view.deselect = null;
    _ = dvui.currentWindow().addEventTextSelect(.{ .start = 0, .end = 0, .target_id = id }) catch return;
    c.view.deselected = true;
}

fn topOf(st: *const State, message: u32) f32 {
    var y: f32 = 10;
    for (st.kept.items[0..@min(message, st.kept.items.len)]) |k| y += k.h;
    return y;
}

/// The last message is the other side's and text is arriving in it: no typing dots needed.
fn streaming(c: *const Chat) bool {
    const ms = c.transcript.messages.items;
    if (ms.len == 0) return false;
    const last = ms[ms.len - 1];
    return last.author == .other and last.parts.items.len > 0;
}

/// The person's bubble: the content fill, the neutral a step up from the window fill a document
/// (and so the chat) sits on, which would not show. The other side's replies have no bubble: they
/// read as the page, the way a document does.
fn bubbleFill() dvui.Color {
    return dvui.themeGet().color(.content, .fill);
}

/// What is around the conversation rather than in it (notes, a done step, a thought): the
/// control text colour, a step back from the window text the messages are in.
fn faded() dvui.Color {
    return dvui.themeGet().color(.control, .text);
}

fn drawHint(c: *Chat, width: f32) void {
    const what = Commands.clientTitle(c.client_id) orelse c.client_id;
    var tl = dvui.textLayout(@src(), .{}, .{
        .gravity_x = 0.5,
        .margin = .{ .y = 40 },
        .background = false,
        .max_size_content = .width(@max(width - 80, 40)),
        .color_text = .{ .color = faded() },
    });
    defer tl.deinit();
    tl.addText(what, .{ .font = dvui.themeGet().font_heading });
    tl.addText("\nAsk anything. Enter sends; Shift+Enter starts a new line.", .{});
}

/// How long a new message takes to fade in, as written (through `core.motion.duration`).
const fade_us = 220_000;

fn drawMessage(c: *Chat, i: usize, m: *Transcript.Message, width: f32, min_h: f32) f32 {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i, .padding = .{ .x = side_pad, .y = 4, .w = side_pad, .h = 4 }, .min_size_content = .{ .h = @max(0, min_h - 8) } });
    const id = row.data().id;
    const avail = @max(width - 2 * side_pad, 60);
    // A message that just arrived fades in. Only while it fades is it wrapped: a message drawn
    // again after scrolling back into view is not new.
    var fade: ?*dvui.AnimateWidget = null;
    if (c.view.fading.get(@intCast(i))) |end| {
        if (dvui.frameTimeNS() < end) {
            fade = dvui.animate(@src(), .{ .kind = .alpha, .duration = core.motion.duration(fade_us), .easing = core.motion.enter }, .{ .expand = .horizontal, .id_extra = i });
        } else _ = c.view.fading.remove(@intCast(i));
    }
    switch (m.author) {
        .note => drawNote(c, i, m, avail),
        .person, .other => if (m.parts.items.len == 0) drawDots(c, i) else drawBubble(c, i, m, avail),
    }
    if (fade) |f| f.deinit();
    row.deinit();
    return if (dvui.minSizeGet(id)) |s| s.h else 0;
}

fn drawNote(c: *Chat, i: usize, m: *Transcript.Message, avail: f32) void {
    _ = c;
    var tl = dvui.textLayout(@src(), .{}, .{
        .gravity_x = 0.5,
        .id_extra = i,
        .background = false,
        .max_size_content = .width(avail * 0.85),
        .color_text = .{ .color = faded() },
        .font = dvui.themeGet().font_body.larger(-1),
    });
    defer tl.deinit();
    for (m.parts.items) |p| if (p == .block and p.block == .text) tl.addText(p.block.text.items, .{});
}

fn drawBubble(c: *Chat, i: usize, m: *Transcript.Message, avail: f32) void {
    const person = m.author == .person;
    const max_w = @floor(avail * @as(f32, if (person) 0.78 else 0.92));
    const inner_max = max_w - bubble_pad.x - bubble_pad.w;
    const inner_w = @min(inner_max, @max(naturalWidth(c, i, m, inner_max), 24));
    const r: f32 = 14;
    const tail: f32 = 4;
    var bubble = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = if (person) 1 else 0,
        .id_extra = i,
        .background = person,
        .color_fill = .{ .color = bubbleFill() },
        .corners = if (person)
            .{ .tl = .round(r), .tr = .round(r), .bl = .round(r), .br = .round(tail) }
        else
            .{ .tl = .round(r), .tr = .round(r), .br = .round(r), .bl = .round(tail) },
        .padding = bubble_pad,
        .min_size_content = .{ .w = inner_w },
        .max_size_content = .width(inner_w),
    });
    defer bubble.deinit();
    for (m.parts.items, 0..) |*p, j| switch (p.*) {
        .block => |*b| drawBlock(c, i, j, b, inner_w, j + 1 == m.parts.items.len),
        .tool => |t| drawTool(c, t, inner_w),
        .question => |q| drawQuestion(c, q, inner_w),
    };
}

/// A text-only message's widest line, so a short reply's bubble hugs it; anything richer takes
/// the whole width.
fn naturalWidth(c: *Chat, i: usize, m: *const Transcript.Message, max: f32) f32 {
    const k = &c.view.kept.items[i];
    if (k.natural_version == m.version) return k.natural_w;
    const font = dvui.themeGet().font_body;
    var w: f32 = 0;
    for (m.parts.items) |p| {
        if (p != .block or p.block != .text) {
            w = max;
            break;
        }
        var lines = std.mem.splitScalar(u8, p.block.text.items, '\n');
        while (lines.next()) |line| w = @max(w, font.textSize(line).w);
        if (w >= max) break;
    }
    k.natural_version = m.version;
    // Markdown's own paragraph padding and a little slack: a short message must never wrap.
    k.natural_w = @min(max, w + 28);
    return k.natural_w;
}

// ---- blocks ---------------------------------------------------------------------------------

fn drawBlock(c: *Chat, i: usize, j: usize, b: *Transcript.Block, w: f32, last: bool) void {
    switch (b.*) {
        .text => |t| markdown(c, partKey(c.chat_id, i, j, 't'), if (c.transcript.messages.items[i].author == .other) revealed(c, i, partKey(c.chat_id, i, j, 'r'), t.items) else t.items, w, i * 64 + j),
        .thought => |t| drawThought(c, partKey(c.chat_id, i, j, 'h'), t.items, w, last and c.busy, i * 64 + j),
        .code => |code| drawCode(c, partKey(c.chat_id, i, j, 'c'), code.language, code.text, w, i * 64 + j),
        .image => |img| drawImage(img, w, i * 64 + j),
        .file => |f| drawFile(c, f.path, f.line, f.title, i * 64 + j),
        .diff => |d| drawDiff(d.path, d.old, d.new, w, i * 64 + j),
        .plan => |p| drawPlan(p, w, i * 64 + j),
    }
}

/// How much of an arriving text block to show: it runs to catch up with what has streamed in,
/// faster the further behind it is (all of it within about a sixth of a second), so a reply types
/// in smoothly instead of in the agent's bursts. History, and everything with motion off, shows
/// whole. Cut on a UTF-8 boundary.
fn revealed(c: *Chat, i: usize, key: u64, text: []const u8) []const u8 {
    const st = &c.view;
    if (core.motion.off() or i < (st.history orelse 0)) return text;
    const gop = st.reveal.getOrPut(c.gpa, key) catch return text;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const shown = gop.value_ptr;
    const len: f32 = @floatFromInt(text.len);
    if (shown.* >= len) return text;
    const behind = len - shown.*;
    const per_second = @max(120.0, behind * 6.0) * core.motion.rate();
    shown.* = @min(len, shown.* + per_second * dvui.secondsSinceLastFrame());
    dvui.refresh(null, @src(), null);
    var n: usize = @intFromFloat(shown.*);
    while (n < text.len and n > 0 and (text[n] & 0xC0) == 0x80) n += 1;
    return text[0..n];
}

/// Markdown through the markdown plugin when it is there; plain wrapped text when it is not.
fn markdown(c: *Chat, key: u64, text: []const u8, w: f32, id_extra: usize) void {
    if (c.host.getServiceTyped(sdk.services.markdown.Api)) |md| {
        md.renderInline(text, c.gpa, .{ .width = w, .id_extra = key }) catch {};
        return;
    }
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .id_extra = id_extra, .max_size_content = .width(w) });
    defer tl.deinit();
    tl.addText(text, .{});
}

fn drawThought(c: *Chat, key: u64, text: []const u8, w: f32, thinking: bool, id_extra: usize) void {
    const open = c.view.open.contains(key);
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = id_extra, .margin = .{ .y = 2, .h = 2 } });
    defer box.deinit();
    if (disclosure(@src(), if (thinking) "Thinking..." else "Thought", if (thinking) null else entypo.light_bulb, open, id_extra)) {
        if (open) _ = c.view.open.remove(key) else c.view.open.put(c.gpa, key, {}) catch {};
    }
    if (!open) return;
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .background = false,
        .margin = .{ .x = 18 },
        .max_size_content = .width(@max(w - 18, 20)),
        .color_text = .{ .color = faded() },
    });
    defer tl.deinit();
    tl.addText(text, .{});
}

/// One quiet clickable line: an icon (the boiling spinner when `tvg` is null: still going), a
/// label and a chevron. True when clicked.
fn disclosure(src: std.builtin.SourceLocation, text: []const u8, tvg: ?[]const u8, open: bool, id_extra: usize) bool {
    var b: dvui.ButtonWidget = undefined;
    b.init(src, .{}, .{ .id_extra = id_extra, .padding = .{ .y = 2, .h = 2 }, .corners = .all(6), .background = false });
    b.processEvents();
    b.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        const color = faded();
        if (tvg) |icon| {
            core.icon.icon(@src(), "disclosure-icon", icon, .{ .fill_color = .{ .color = color } }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 }, .margin = .{ .w = 6 } });
        } else core.dialogs.bubbleSpinner(@src(), .{ .gravity_y = 0.5, .min_size_content = .{ .w = 14, .h = 14 }, .margin = .{ .w = 6 } }, .{});
        dvui.labelNoFmt(@src(), text, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = color } });
        core.icon.icon(@src(), "disclosure-chevron", if (open) entypo.chevron_small_down else entypo.chevron_small_right, .{ .fill_color = .{ .color = color } }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 } });
    }
    const clicked = b.clicked();
    b.deinit();
    return clicked;
}

fn drawCode(c: *Chat, key: u64, language: []const u8, text: []const u8, w: f32, id_extra: usize) void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = id_extra, .margin = .{ .y = 4, .h = 4 } });
    defer box.deinit();
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer bar.deinit();
        // The fence names its language itself; this bar only offers the copy.
        if (dvui.button(@src(), "Copy", .{}, .{ .gravity_x = 1, .gravity_y = 0.5, .padding = .{ .x = 6, .y = 1, .w = 6, .h = 1 }, .corners = .all(6) })) dvui.clipboardTextSet(text);
    }
    // Fenced and drawn as markdown draws a fence: highlighted by whichever plugin knows the
    // language, in the same panel a markdown document's code sits in.
    const fence = std.fmt.allocPrint(dvui.currentWindow().arena(), "```{s}\n{s}\n```\n", .{ language, std.mem.trimEnd(u8, text, "\n") }) catch return;
    markdown(c, key, fence, w, id_extra);
}

fn drawImage(img: Transcript.Block.Image, w: f32, id_extra: usize) void {
    const source: dvui.ImageSource = .{ .imageFile = .{ .bytes = img.bytes, .name = if (img.alt.len > 0) img.alt else "image" } };
    const size = dvui.ImageSource.size(source) catch {
        dvui.label(@src(), "(an image fizzy cannot show: {s})", .{img.mime}, .{ .color_text = .{ .color = faded() }, .id_extra = id_extra });
        return;
    };
    if (size.w <= 0 or size.h <= 0) return;
    const scale = @min(@min(w, size.w) / size.w, 360 / size.h);
    _ = dvui.image(@src(), .{ .source = source, .shrink = .ratio }, .{
        .id_extra = id_extra,
        .min_size_content = .{ .w = size.w * scale, .h = size.h * scale },
        .max_size_content = .{ .w = size.w * scale, .h = size.h * scale },
        .corners = .all(8),
        .margin = .{ .y = 4, .h = 4 },
        .label = .{ .text = img.alt },
    });
}

fn drawFile(c: *Chat, path: []const u8, line: u32, title: []const u8, id_extra: usize) void {
    const theme = dvui.themeGet();
    var b: dvui.ButtonWidget = undefined;
    b.init(@src(), .{}, .{ .id_extra = id_extra, .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 }, .corners = .all(6), .margin = .{ .y = 2, .h = 2 } });
    b.processEvents();
    b.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer row.deinit();
        const link = theme.color(.highlight, .fill);
        core.icon.icon(@src(), "file-link", entypo.text_document, .{ .fill_color = .{ .color = link } }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 }, .margin = .{ .w = 6 } });
        const name = if (title.len > 0) title else std.fs.path.basename(path);
        if (line > 0) {
            dvui.label(@src(), "{s}:{d}", .{ name, line }, .{ .gravity_y = 0.5, .color_text = .{ .color = link } });
        } else dvui.labelNoFmt(@src(), name, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = link } });
    }
    if (b.clicked()) _ = c.host.openFile(.{ .path = path }) catch {};
    b.deinit();
}

/// `old` to `new` as the lines that changed: the same lines at the start and the end are left
/// out, the rest shown `-` then `+`, at most a screenful each.
fn drawDiff(path: []const u8, old: []const u8, new: []const u8, w: f32, id_extra: usize) void {
    const theme = dvui.themeGet();
    const arena = dvui.currentWindow().arena();
    var a: std.ArrayListUnmanaged([]const u8) = .empty;
    var b: std.ArrayListUnmanaged([]const u8) = .empty;
    if (old.len > 0) {
        var it = std.mem.splitScalar(u8, old, '\n');
        while (it.next()) |l| a.append(arena, l) catch return;
    }
    var it = std.mem.splitScalar(u8, new, '\n');
    while (it.next()) |l| b.append(arena, l) catch return;
    var pre: usize = 0;
    while (pre < a.items.len and pre < b.items.len and std.mem.eql(u8, a.items[pre], b.items[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.items.len - pre and suf < b.items.len - pre and
        std.mem.eql(u8, a.items[a.items.len - 1 - suf], b.items[b.items.len - 1 - suf])) suf += 1;
    const removed = a.items[pre .. a.items.len - suf];
    const added = b.items[pre .. b.items.len - suf];

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = theme.color(.content, .fill).opacity(0.6) },
        .corners = .all(8),
        .padding = .all(8),
        .margin = .{ .y = 4, .h = 4 },
        .max_size_content = .width(w - 16),
    });
    defer box.deinit();
    dvui.label(@src(), "{s}  line {d}", .{ std.fs.path.basename(path), pre + 1 }, .{ .color_text = .{ .color = faded() } });
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .font = theme.font_mono, .max_size_content = .width(w - 16) });
    defer tl.deinit();
    const cap = 40;
    const minus = theme.color(.err, .text);
    const plus = theme.color(.highlight, .fill);
    for (removed[0..@min(removed.len, cap)]) |l| {
        tl.addText("- ", .{ .color_text = .{ .color = minus } });
        tl.addText(l, .{ .color_text = .{ .color = minus } });
        tl.addText("\n", .{});
    }
    if (removed.len > cap) tl.format("  ... {d} more removed\n", .{removed.len - cap}, .{ .color_text = .{ .color = faded() } });
    for (added[0..@min(added.len, cap)]) |l| {
        tl.addText("+ ", .{ .color_text = .{ .color = plus } });
        tl.addText(l, .{ .color_text = .{ .color = plus } });
        tl.addText("\n", .{});
    }
    if (added.len > cap) tl.format("  ... {d} more added\n", .{added.len - cap}, .{ .color_text = .{ .color = faded() } });
}

fn drawPlan(entries: []const Transcript.Block.PlanEntry, w: f32, id_extra: usize) void {
    const theme = dvui.themeGet();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .id_extra = id_extra,
        .background = true,
        .color_fill = .{ .color = theme.color(.content, .fill).opacity(0.5) },
        .corners = .all(8),
        .padding = .all(8),
        .margin = .{ .y = 4, .h = 4 },
    });
    defer box.deinit();
    for (entries, 0..) |e, n| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n, .margin = .{ .y = 1, .h = 1 } });
        defer row.deinit();
        const icon, const color = switch (e.status) {
            .completed => .{ entypo.check, theme.color(.highlight, .fill) },
            .in_progress => .{ entypo.dots_three_horizontal, theme.color(.content, .text) },
            .pending => .{ entypo.dot_single, faded() },
        };
        core.icon.icon(@src(), "plan-mark", icon, .{ .fill_color = .{ .color = color } }, .{ .gravity_y = 0, .min_size_content = .{ .w = 12, .h = 12 }, .margin = .{ .y = 3, .w = 8 } });
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .max_size_content = .width(@max(w - 40, 20)), .color_text = if (e.status == .completed) .{ .color = faded() } else null });
        defer tl.deinit();
        tl.addText(e.text, .{});
    }
}

// ---- tool steps and questions ---------------------------------------------------------------

fn kindIcon(kind: api.Tool.Kind) []const u8 {
    return switch (kind) {
        .read => entypo.eye,
        .edit => entypo.pencil,
        .delete => entypo.trash,
        .move => entypo.swap,
        .search => entypo.magnifying_glass,
        .execute => entypo.code,
        .think => entypo.light_bulb,
        .fetch => entypo.globe,
        .other => entypo.tools,
    };
}

fn drawTool(c: *Chat, tid: api.ToolId, w: f32) void {
    const theme = dvui.themeGet();
    const t = &c.transcript.tools.items[tid];
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = tid, .margin = .{ .y = 1, .h = 1 } });
    defer box.deinit();
    {
        var b: dvui.ButtonWidget = undefined;
        b.init(@src(), .{}, .{ .expand = .horizontal, .padding = .{ .x = 4, .y = 3, .w = 4, .h = 3 }, .corners = .all(6), .background = false });
        b.processEvents();
        b.drawBackground();
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            const done = t.status == .done;
            const text_color = if (done) faded() else theme.color(.content, .text);
            core.icon.icon(@src(), "tool-kind", kindIcon(t.kind), .{ .fill_color = .{ .color = text_color } }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 }, .margin = .{ .w = 8 } });
            // The status sits at the right edge; the title takes what is left, on one line.
            switch (t.status) {
                .pending, .running => core.dialogs.bubbleSpinner(@src(), .{ .gravity_x = 1, .gravity_y = 0.5, .min_size_content = .{ .w = 14, .h = 14 } }, .{}),
                .done => core.icon.icon(@src(), "tool-done", entypo.check, .{ .fill_color = .{ .color = theme.color(.highlight, .fill) } }, .{ .gravity_x = 1, .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 } }),
                .failed => core.icon.icon(@src(), "tool-failed", entypo.cross, .{ .fill_color = .{ .color = theme.color(.err, .text) } }, .{ .gravity_x = 1, .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 } }),
            }
            if (t.content.items.len > 0) core.icon.icon(@src(), "tool-open", if (t.open) entypo.chevron_small_down else entypo.chevron_small_right, .{ .fill_color = .{ .color = faded() } }, .{ .gravity_x = 1, .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 }, .margin = .{ .w = 4 } });
            dvui.labelNoFmt(@src(), t.title.items, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = text_color }, .max_size_content = .width(@max(w - 60, 20)) });
        }
        if (b.clicked() and t.content.items.len > 0) {
            t.open = !t.open;
        }
        b.deinit();
    }
    if (t.question) |q| drawQuestion(c, q, w);
    if (!t.open) return;
    var content = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .x = 20, .y = 2, .h = 4 },
        .background = true,
        .color_fill = .{ .color = theme.color(.content, .fill).opacity(0.5) },
        .corners = .all(8),
        .padding = .all(8),
    });
    defer content.deinit();
    const inner = @max(w - 36, 20);
    for (t.content.items, 0..) |*b, n| switch (b.*) {
        // A tool's text is its output: shown as it came, monospace, the first screenful.
        .text, .thought => |s| drawOutput(s.items, inner, n),
        .code => |code| drawOutput(code.text, inner, n),
        .image => |img| drawImage(img, inner, n),
        .file => |f| drawFile(c, f.path, f.line, f.title, n),
        .diff => |d| drawDiff(d.path, d.old, d.new, inner, n),
        .plan => |p| drawPlan(p, inner, n),
    };
}

fn drawOutput(text: []const u8, w: f32, id_extra: usize) void {
    const cap = 30;
    var lines: usize = 0;
    var end: usize = 0;
    while (lines < cap) : (lines += 1) end = (std.mem.indexOfScalarPos(u8, text, end, '\n') orelse {
        end = text.len;
        break;
    }) + 1;
    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .id_extra = id_extra, .font = dvui.themeGet().font_mono, .max_size_content = .width(w) });
    defer tl.deinit();
    tl.addText(std.mem.trimEnd(u8, text[0..@min(end, text.len)], "\n"), .{});
    if (end < text.len) {
        const more = std.mem.count(u8, text[end..], "\n") + 1;
        tl.format("\n... {d} more lines", .{more}, .{ .color_text = .{ .color = faded() } });
    }
}

fn drawQuestion(c: *Chat, qid: api.QuestionId, w: f32) void {
    const theme = dvui.themeGet();
    const q = &c.transcript.questions.items[qid];
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .id_extra = qid, .margin = .{ .x = 20, .y = 2, .h = 4 } });
    defer box.deinit();
    switch (q.answer) {
        .open => {
            if (q.text.len > 0) {
                var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .max_size_content = .width(@max(w - 20, 20)) });
                tl.addText(q.text, .{});
                tl.deinit();
            }
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .margin = .{ .y = 4 } });
            defer row.deinit();
            for (q.options, 0..) |o, n| {
                const style: dvui.Theme.Style.Name = switch (o.kind) {
                    .allow, .allow_always => .highlight,
                    else => .control,
                };
                if (dvui.button(@src(), o.label, .{}, .{ .id_extra = n, .style = style, .corners = .all(8), .margin = .{ .w = 6 }, .padding = .{ .x = 10, .y = 4, .w = 10, .h = 4 } })) {
                    c.choose(qid, @intCast(n));
                }
            }
        },
        .chosen => |n| {
            const o = q.options[n];
            const allowed = o.kind == .allow or o.kind == .allow_always;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer row.deinit();
            core.icon.icon(@src(), "answer", if (allowed) entypo.check else entypo.cross, .{ .fill_color = .{ .color = faded() } }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 10, .h = 10 }, .margin = .{ .w = 6 } });
            dvui.labelNoFmt(@src(), o.label, .{}, .{ .gravity_y = 0.5, .color_text = .{ .color = faded() }, .font = theme.font_body.larger(-1) });
        },
        .cancelled => dvui.labelNoFmt(@src(), "Not answered", .{}, .{ .color_text = .{ .color = faded() }, .font = theme.font_body.larger(-1) }),
    }
}

// ---- while a turn runs ----------------------------------------------------------------------

fn drawTyping(c: *Chat, width: f32) void {
    _ = width;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = side_pad, .y = 4, .w = side_pad, .h = 4 } });
    defer row.deinit();
    drawDots(c, 0);
}

/// fizzy's spinner, boiling, on its own where the reply will be: what a turn that has not said
/// anything yet looks like. Not in a bubble: there is nothing to hold yet.
fn drawDots(c: *Chat, id_extra: usize) void {
    _ = c;
    core.dialogs.bubbleSpinner(@src(), .{ .id_extra = id_extra, .min_size_content = .{ .w = 26, .h = 26 }, .gravity_y = 0.5, .margin = .{ .x = 4, .y = 2, .h = 2 } }, .{});
}

// ---- the input ------------------------------------------------------------------------------

/// The message box: what is attached, the text, and under it a row of what goes with the message:
/// + to attach files and images, the client's settings (an agent's model, its mode) as dropdowns,
/// and Send, or Stop while a turn runs.
fn drawInput(c: *Chat) void {
    const theme = dvui.themeGet();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 1, .padding = .{ .x = 12, .y = 8, .w = 12, .h = 10 } });
    defer col.deinit();

    // Packed from the bottom: the row of controls, then the text above it, then what is attached.
    var send_now = false;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_y = 1, .margin = .{ .y = 6 } });
        defer row.deinit();
        // Send or Stop at the right, packed first so the settings take what is left.
        {
            const busy = c.busy;
            var b: dvui.ButtonWidget = undefined;
            b.init(@src(), .{}, .{
                .gravity_x = 1,
                .gravity_y = 0.5,
                .padding = .all(7),
                .corners = .all(16),
                .background = true,
                .color_fill = .{ .color = if (busy) theme.color(.control, .fill) else theme.color(.highlight, .fill) },
                .label = .{ .text = if (busy) "Stop" else "Send" },
            });
            b.processEvents();
            b.drawBackground();
            // On the highlight, the icon takes the content's fill, as text on a highlighted control would.
            core.icon.icon(@src(), "send", if (busy) entypo.controller_stop else entypo.paper_plane, .{ .fill_color = .{ .color = if (busy) theme.color(.content, .text) else theme.color(.content, .fill) } }, .{ .min_size_content = .{ .w = 14, .h = 14 } });
            if (b.clicked()) {
                if (busy) c.cancel() else send_now = true;
            }
            b.deinit();
        }
        // + : attach files and images.
        {
            var b: dvui.ButtonWidget = undefined;
            b.init(@src(), .{}, .{ .gravity_y = 0.5, .padding = .all(6), .corners = .all(14), .label = .{ .text = "Attach" } });
            b.processEvents();
            b.drawBackground();
            core.icon.icon(@src(), "attach", entypo.plus, .{ .fill_color = .{ .color = theme.color(.control, .text) } }, .{ .min_size_content = .{ .w = 14, .h = 14 } });
            if (b.clicked()) {
                attach_to = c.chat_id;
                c.host.showOpenFileDialog(onAttach, &.{}, "", if (c.folder.len > 0) c.folder else null);
            }
            b.deinit();
        }
        // What the client offers to set, as compact dropdowns.
        for (c.settings, 0..) |setting, n| drawSetting(c, setting, n);
    }

    var te: dvui.TextEntryWidget = undefined;
    te.init(@src(), .{
        .multiline = true,
        .break_lines = true,
        .text = .{ .array_list = .{ .backing = &c.input, .allocator = c.gpa, .limit = 64 * 1024 } },
        .placeholder = "Message",
    }, .{
        .expand = .horizontal,
        .gravity_y = 1,
        .corners = .all(14),
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        // A line tall to start, growing with what is typed up to six lines, then scrolling.
        .min_size_content = .{ .w = 40, .h = theme.font_body.lineHeight() },
        .max_size_content = .{ .w = std.math.floatMax(f32), .h = theme.font_body.lineHeight() * 6 },
    });
    // Enter sends; Shift+Enter is a new line, as the entry would make it.
    for (dvui.events()) |*e| {
        if (!te.matchEvent(e)) continue;
        if (e.evt == .key and e.evt.key.action == .down and e.evt.key.code == .enter and !e.evt.key.mod.shift()) {
            e.handle(@src(), te.data());
            send_now = true;
        }
    }
    te.processEvents();
    te.draw();
    te.deinit();

    if (c.attached.items.len > 0) drawAttached(c);
    if (send_now and !c.busy and c.send(c.input.items)) c.input.clearRetainingCapacity();
}

/// The chat a file dialog's choice is for: the dialog's callback has no context of its own.
var attach_to: ?api.ChatId = null;

fn onAttach(paths: ?[][:0]const u8) void {
    const id = attach_to orelse return;
    attach_to = null;
    const chosen = paths orelse return;
    const c = Commands.chatFor(id) orelse return;
    for (chosen) |p| c.attach(p);
    sdk.host().refresh();
}

/// What is attached and not sent yet: a chip each, its name and an x to take it off.
fn drawAttached(c: *Chat) void {
    const theme = dvui.themeGet();
    var row = dvui.flexbox(@src(), .{}, .{ .expand = .horizontal, .gravity_y = 1, .margin = .{ .h = 6 } });
    defer row.deinit();
    var remove: ?usize = null;
    for (c.attached.items, 0..) |a, n| {
        var chip = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = n, .background = true, .color_fill = .{ .color = theme.color(.content, .fill) }, .corners = .all(10), .padding = .{ .x = 8, .y = 3, .w = 4, .h = 3 }, .margin = .{ .w = 6, .h = 4 } });
        defer chip.deinit();
        core.icon.icon(@src(), "attached", if (a.image()) entypo.image else entypo.text_document, .{ .fill_color = .{ .color = faded() } }, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 12, .h = 12 }, .margin = .{ .w = 6 } });
        dvui.labelNoFmt(@src(), std.fs.path.basename(a.path), .{}, .{ .gravity_y = 0.5 });
        if (dvui.buttonIcon(@src(), "Remove", entypo.cross, .{}, .{}, .{ .gravity_y = 0.5, .padding = .all(3), .corners = .all(8), .min_size_content = .{ .w = 10, .h = 10 }, .margin = .{ .x = 4 } })) remove = n;
    }
    if (remove) |n| c.detach(n);
}

/// One setting as a compact dropdown: its current choice's name, the rest a click away.
fn drawSetting(c: *Chat, setting: api.Setting, n: usize) void {
    const arena = dvui.currentWindow().arena();
    const names = arena.alloc([]const u8, setting.choices.len) catch return;
    var current: usize = 0;
    for (setting.choices, names, 0..) |ch, *name, k| {
        name.* = ch.name;
        if (std.mem.eql(u8, ch.value, setting.current)) current = k;
    }
    if (names.len == 0) return;
    var choice = current;
    if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{
        .id_extra = n,
        .gravity_y = 0.5,
        .margin = .{ .x = 6 },
        .corners = .all(10),
        .label = .{ .text = setting.name },
    })) {
        if (choice != current) c.chooseSetting(setting.id, setting.choices[choice].value);
    }
}

fn drawUnavailable(c: *Chat) void {
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .gravity_y = 1,
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill) },
        .corners = .all(10),
        .margin = .all(12),
        .padding = .all(10),
    });
    defer tl.deinit();
    tl.format("This conversation belongs to the `{s}` plugin, which is not loaded. It reads as it was; install or enable that plugin to continue it.", .{c.client_id}, .{});
}
