/* Copyright (C) 2024 HyperXTalk Contributors

This file is part of HyperXTalk.

HyperXTalk is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License v3 as published by the Free
Software Foundation.  */

// vlc-player-mac.mm — macOS helper functions for MCVLCPlayer.
//
// Creates and manages the NSView that VLC renders into.

#import <Cocoa/Cocoa.h>

#include "globdefs.h"
#include "platform.h"
#include "graphics_util.h"

// ---------------------------------------------------------------------------
// MCVLCPlayerView — a plain layer-hosting NSView for VLC to render into.
// ---------------------------------------------------------------------------

@interface MCVLCPlayerView : NSView
{
    // Called (async, on the main queue) the first time the view's frame
    // transitions from zero to non-zero.  MCVLCPlayer::Start() arms this
    // callback when the native layer has not yet applied its deferred
    // geometry — the callback fires when that deferred geometry is finally
    // applied by MCNativeLayerMac::doSetGeometry() during the first paint.
    void  (*_frameReadyCb)(void *);
    void   *_frameReadyOpaque;
    BOOL    _frameCallbackFired;   // guard: fire at most once per view

    // Set by MCVLCDestroyNSView() to prevent the queued block from calling
    // back into a freed MCVLCPlayer.
    BOOL    _frameCancelled;
}
- (void)setFrameReadyCallback:(void (*)(void *))callback opaque:(void *)opaque;
- (void)cancelFrameCallback;
// If the frame is already non-zero when the callback is armed, fire it on the
// next run-loop turn rather than waiting for a future setFrame: transition.
- (void)fireCallbackDeferredIfFrameReady;
@end

@implementation MCVLCPlayerView

- (void)setFrameReadyCallback:(void (*)(void *))callback opaque:(void *)opaque
{
    _frameReadyCb      = callback;
    _frameReadyOpaque  = opaque;
    _frameCallbackFired = NO;
    _frameCancelled    = NO;
}

- (void)cancelFrameCallback
{
    _frameCancelled = YES;
}

- (void)fireCallbackDeferredIfFrameReady
{
    NSRect t_frame = [self frame];
    if (NSWidth(t_frame) <= 0 || NSHeight(t_frame) <= 0)
        return;   // frame still zero — setFrame: will fire the callback later
    if (_frameReadyCb == nullptr || _frameCallbackFired)
        return;

    // Mark fired now so setFrame: won't double-fire.
    _frameCallbackFired = YES;

    void (*cb)(void *) = _frameReadyCb;
    void *op           = _frameReadyOpaque;
    [self retain];
    MCVLCPlayerView *view = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!view->_frameCancelled)
            cb(op);
        [view release];
    });
}

- (BOOL)isOpaque
{
    return YES;
}

// Do NOT override wantsLayer — VLC 3's macosx vout module uses OpenGL and
// requires a plain (non-layer-backed) NSView as its rendering target.
// A layer-backed view conflicts with VLC's GL context setup and produces
// a blank output.  Use drawRect: for the black fill instead.

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor blackColor] set];
    NSRectFill(dirtyRect);
}

// Called by AppKit (and directly by MCNativeLayerMac::doSetGeometry) whenever
// the view's frame changes.  We use the first zero→non-zero transition to
// signal MCVLCPlayer::Start() that the native layer has applied its deferred
// geometry and VLC's vout can now be safely initialized.
//
// Background: MCNativeLayer::m_rect starts as {0,0,0,0} and
// m_defer_geometry_changes starts true, so doAttach() calls
// doSetGeometry({0,0,0,0}).  The actual player rect lives in m_deferred_rect
// and is applied in OnPaint() — which runs asynchronously.  If Start() is
// called in the same run-loop turn as attachplayer() (e.g. from an openStack
// handler), libvlc_media_player_play() fires while the view has a zero frame.
// VLC's macOS vout then creates a zero-size GL surface and silently fails to
// render video.  This override catches the moment the frame becomes valid so
// the deferred play can be triggered at exactly the right time.
- (void)setFrame:(NSRect)frameRect
{
    BOOL t_was_zero = (NSWidth([self frame]) == 0 || NSHeight([self frame]) == 0);
    [super setFrame: frameRect];

    BOOL t_now_nonzero = (NSWidth(frameRect) > 0 && NSHeight(frameRect) > 0);
    if (t_was_zero && t_now_nonzero && !_frameCallbackFired
        && _frameReadyCb != nullptr)
    {
        _frameCallbackFired = YES;

        // Retain self so the view remains valid until the block fires.
        // _frameCancelled is set by MCVLCDestroyNSView() if the player is
        // torn down before the block runs.
        void (*cb)(void *) = _frameReadyCb;
        void *op           = _frameReadyOpaque;
        [self retain];
        MCVLCPlayerView *view = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!view->_frameCancelled)
                cb(op);
            [view release];
        });
    }
}

- (void)dealloc
{
    _frameReadyCb      = nullptr;
    _frameReadyOpaque  = nullptr;
    [super dealloc];
}

@end

// ---------------------------------------------------------------------------
// C helper API called from vlc-player.cpp
// ---------------------------------------------------------------------------

extern "C"
{

void *MCVLCCreateNSView(void)
{
    MCVLCPlayerView *t_view =
        [[MCVLCPlayerView alloc] initWithFrame: NSZeroRect];
    if (t_view == nil)
        return nullptr;

    return (void *)t_view;
}

void MCVLCDestroyNSView(void *p_view)
{
    if (p_view == nullptr)
        return;

    MCVLCPlayerView *t_view = (MCVLCPlayerView *)p_view;

    // Prevent any queued setFrame: block from calling back into the player.
    [t_view cancelFrameCallback];

    // Remove from superview if it has one.
    if ([t_view superview] != nil)
        [t_view removeFromSuperview];

    [t_view release];
}

void MCVLCReparentNSView(void *p_view, void *p_parent_view)
{
    if (p_view == nullptr)
        return;

    MCVLCPlayerView *t_view   = (MCVLCPlayerView *)p_view;
    NSView          *t_parent = (NSView *)p_parent_view;

    // Remove from any existing superview first.
    if ([t_view superview] != nil && [t_view superview] != t_parent)
        [t_view removeFromSuperview];

    if (t_parent != nil && [t_view superview] == nil)
        [t_parent addSubview: t_view];
}

// Arm a one-shot callback that fires (asynchronously on the main queue) the
// first time the view's frame transitions from zero to non-zero.
//
// If the view already has a non-zero frame at the time this is called, the
// callback is dispatched immediately on the next main-queue turn instead of
// waiting for a future setFrame: call.  This handles the reopen case where
// MCNativeLayerMac has already applied its deferred geometry before Start()
// runs, so the setFrame: zero→non-zero transition already happened.
//
// Deferring play to the next run-loop turn (even when the frame is already
// valid) is critical: it lets AppKit finish all pending layout and compositing
// callbacks for the current turn before VLC initialises its vout surface.
void MCVLCSetFrameReadyCallback(void *p_view,
                                void (*p_callback)(void *),
                                void  *p_opaque)
{
    if (p_view == nullptr)
        return;

    MCVLCPlayerView *t_view = (MCVLCPlayerView *)p_view;
    [t_view setFrameReadyCallback: p_callback opaque: p_opaque];

    // If the frame is already non-zero, fire the callback on the next
    // run-loop turn (mirrors what the setFrame: override would do for the
    // zero→non-zero transition).
    [t_view fireCallbackDeferredIfFrameReady];
}

// Returns true when the view has a non-zero frame.
bool MCVLCViewHasNonZeroFrame(void *p_view)
{
    if (p_view == nullptr)
        return false;

    MCVLCPlayerView *t_view = (MCVLCPlayerView *)p_view;
    NSRect t_frame = [t_view frame];
    return NSWidth(t_frame) > 0 && NSHeight(t_frame) > 0;
}

// Returns true when the view is part of a live window hierarchy.
bool MCVLCViewHasWindow(void *p_view)
{
    if (p_view == nullptr)
        return false;

    MCVLCPlayerView *t_view = (MCVLCPlayerView *)p_view;
    return [t_view window] != nil;
}

void MCVLCSyncNSView(void *p_view, MCRectangle p_rect, bool p_visible)
{
    if (p_view == nullptr)
        return;

    MCVLCPlayerView *t_view = (MCVLCPlayerView *)p_view;

    if (!p_visible)
    {
        [t_view setHidden: YES];
        return;
    }

    if (p_rect.width == 0 && p_rect.height == 0)
    {
        // Rect not yet set (native layer hasn't applied deferred geometry yet).
        // Don't position the view, but don't hide it either — the native layer
        // will call setFrame: with the real rect shortly, and we must be visible
        // when that happens so VLC's vout renders correctly.
        [t_view setHidden: NO];
        return;
    }

    NSView *t_parent = [t_view superview];
    if (t_parent == nil)
    {
        // Not yet embedded — nothing to position.
        [t_view setHidden: NO];
        return;
    }

    // Convert from HyperXTalk (top-left origin) to Cocoa (bottom-left origin).
    NSRect t_parent_bounds = [t_parent bounds];
    NSRect t_frame = NSMakeRect(
        p_rect.x,
        (CGFloat)t_parent_bounds.size.height - p_rect.y - p_rect.height,
        p_rect.width,
        p_rect.height);

    [t_view setFrame: t_frame];
    [t_view setHidden: NO];
}

// Dump the full subview tree of MCVLCPlayerView to stderr.
// Called 600 ms after play() to confirm VLC added its rendering subview.
void MCVLCDumpViewHierarchy(void *p_view)
{
    if (p_view == nullptr)
        return;

    MCVLCPlayerView *t_root = (MCVLCPlayerView *)p_view;
    [t_root retain];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)),
        dispatch_get_main_queue(),
        ^{
            NSRect t_rf = [t_root frame];
            fprintf(stderr,
                    "[VLC-hier] MCVLCPlayerView %p frame=(%.0f,%.0f,%.0f,%.0f)"
                    " hidden=%d inWindow=%d\n",
                    (void *)t_root,
                    t_rf.origin.x, t_rf.origin.y,
                    t_rf.size.width, t_rf.size.height,
                    (int)[t_root isHidden],
                    (int)([t_root window] != nil));

            NSArray<NSView *> *t_subs = [t_root subviews];
            fprintf(stderr, "[VLC-hier]   subviews: %lu\n",
                    (unsigned long)[t_subs count]);
            for (NSView *sv in t_subs)
            {
                NSRect sf = [sv frame];
                fprintf(stderr,
                        "[VLC-hier]     %s %p"
                        " frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d\n",
                        [[sv className] UTF8String], (void *)sv,
                        sf.origin.x, sf.origin.y,
                        sf.size.width, sf.size.height,
                        (int)[sv isHidden]);
            }

            // Also dump the superview chain so we can see if any ancestor is hidden.
            NSView *t_sv = [t_root superview];
            int t_depth = 0;
            while (t_sv != nil && t_depth < 6)
            {
                NSRect pf = [t_sv frame];
                fprintf(stderr,
                        "[VLC-hier] superview[%d] %s %p"
                        " frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d\n",
                        t_depth,
                        [[t_sv className] UTF8String], (void *)t_sv,
                        pf.origin.x, pf.origin.y,
                        pf.size.width, pf.size.height,
                        (int)[t_sv isHidden]);
                t_sv = [t_sv superview];
                t_depth++;
            }

            [t_root release];
        });
}

} // extern "C"
