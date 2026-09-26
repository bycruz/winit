// winit's macos half: a window, the events that happen to it, and the clipboard, said in
// Objective-C and compiled into a shared library by this package's build script. What is on the
// other side of it is Lua over the FFI, which is where the rest of the backend lives.
//
// Why a shim at all: a window on this platform is not a handle a program makes calls on, it is an
// object that is sent messages, and the messages it is sent back -- a click, a key, a resize --
// arrive as objects of another shape again. Saying that in Lua means reaching the runtime with
// `objc_msgSend` cast to every signature used, and every delegate callback would be a Lua closure
// the runtime has to be given a C function to call. A page of Objective-C does all of it once,
// and what crosses back is a queue of plain values the Lua side reads a struct at a time.
//
// The shape of the crossing is a pull: nothing here runs a loop of its own, and the program asks
// for the next event with a deadline on it. That is what a loop that waits, one that polls, and
// one with a caret to blink all want out of the same call.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#include <string.h>

#define WM_MAX_WINDOWS 16
#define WM_QUEUE_CAPACITY 64
#define WM_TEXT_MAX 64
#define WM_PATHS_MAX 8192

// What an event is, as the number the struct carries. The Lua side names them the same way.
enum {
	WM_WINDOW_CLOSE = 1,
	WM_WINDOW_RESIZE = 2,
	WM_FOCUS_IN = 3,
	WM_FOCUS_OUT = 4,
	WM_MOUSE_MOVE = 5,
	WM_MOUSE_PRESS = 6,
	WM_MOUSE_RELEASE = 7,
	WM_MOUSE_SCROLL = 8,
	WM_KEY_PRESS = 9,
	WM_KEY_RELEASE = 10,
	WM_FILE_DROP = 11
};

// What one event carries. It is written and read whole, so every field is a plain value -- a
// pointer would be one the Lua side would have to know how to free, and text that outlives the
// call is what the fixed buffers are for. The declaration is mirrored in the FFI on the other
// side, field for field and in this order.
typedef struct {
	int type;
	int window;
	double x, y;
	double width, height;
	double dx, dy;
	int button;
	unsigned short keycode;
	unsigned int modifiers;
	int repeated;
	char text[WM_TEXT_MAX];
	char paths[WM_PATHS_MAX];
} winit_macos_event;

// The mouse button numbers of this platform, which are not the ones a program is handed: the
// middle button sits between the other two rather than after them.
enum {
	WM_BUTTON_LEFT = 0,
	WM_BUTTON_RIGHT = 1,
	WM_BUTTON_MIDDLE = 2
};

// A key press says which key it was, and that is all: what a key types is the text alongside it,
// and a program that reads what a player wrote wants the letter rather than the key.
enum {
	WM_KEY_LEFT_SHIFT = 56,
	WM_KEY_RIGHT_SHIFT = 60,
	WM_KEY_LEFT_CONTROL = 59,
	WM_KEY_RIGHT_CONTROL = 62,
	WM_KEY_LEFT_OPTION = 58,
	WM_KEY_RIGHT_OPTION = 61,
	WM_KEY_LEFT_COMMAND = 55,
	WM_KEY_RIGHT_COMMAND = 54,
	WM_KEY_CAPS_LOCK = 57
};

// The cursor this window is asked for, and how far the pointer is held: the values are the ones
// the Lua side hands over, so what is here is the last leg of that translation.
enum {
	WM_CURSOR_ARROW = 0,
	WM_CURSOR_HAND = 1
};

enum {
	WM_GRAB_NONE = 0,
	WM_GRAB_CONTAIN = 1,
	WM_GRAB_LOCKED = 2
};

static void wm_push(const winit_macos_event *event);
void winit_macos_window_set_grab(int handle, int mode);

// Views are asked whether they can take the keyboard so that a window is one a key can reach.
// Both key methods are swallowed rather than passed on: a key a program hears about is not one
// the system should beep at, and the menu's own shortcuts are answered before a view sees a key
// at all -- see where events are sent on.
@interface WinitView : NSView
@property (nonatomic) int handle;
@property (nonatomic) int grab;
@end

@implementation WinitView
- (BOOL)acceptsFirstResponder { return YES; }
// A window of this is a place a program draws in, so the system is not asked to paint it first:
// what would show under a frame being resized is the system's own colour, which is a white flash.
- (BOOL)isOpaque { return YES; }
- (void)keyDown:(NSEvent *)event { }
- (void)keyUp:(NSEvent *)event { }
@end

// What the system tells a window about itself: that it was resized, that it took or lost the
// keyboard, that it is being closed, and that files were let go over it. Each of those is pushed
// as an event rather than handed on, and a close in particular is a question rather than an
// order: what is pushed is that the window wants to close, and whether it does is the program's.
@interface WinitDelegate : NSObject <NSWindowDelegate>
@property (nonatomic) int handle;
@end

@implementation WinitDelegate
- (void)push:(int)type {
	winit_macos_event event;
	memset(&event, 0, sizeof(event));
	event.type = type;
	event.window = self.handle;

	wm_push(&event);
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
	[self push:WM_WINDOW_CLOSE];
	return NO;
}

- (void)windowDidResize:(NSNotification *)notification {
	NSWindow *window = notification.object;
	NSRect bounds = [[window contentView] bounds];

	winit_macos_event event;
	memset(&event, 0, sizeof(event));
	event.type = WM_WINDOW_RESIZE;
	event.window = self.handle;
	event.width = bounds.size.width;
	event.height = bounds.size.height;

	wm_push(&event);
}

- (void)windowDidBecomeKey:(NSNotification *)notification { [self push:WM_FOCUS_IN]; }
- (void)windowDidResignKey:(NSNotification *)notification { [self push:WM_FOCUS_OUT]; }

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return NSDragOperationCopy; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return YES; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
	NSPasteboard *pasteboard = [sender draggingPasteboard];
	NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[ [NSURL class] ]
		options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];

	if (urls.count == 0) {
		return NO;
	}

	NSView *view = [[sender draggingDestinationWindow] contentView];
	NSPoint point = [view convertPoint:[sender draggingLocation] fromView:nil];

	// Where a drop lands is counted from the top left, which is where a program counts from, and
	// this platform counts a view's own points from the bottom left.
	winit_macos_event event;
	memset(&event, 0, sizeof(event));
	event.type = WM_FILE_DROP;
	event.window = self.handle;
	event.x = point.x;
	event.y = [view bounds].size.height - point.y;

	NSMutableString *paths = [NSMutableString string];

	for (NSURL *url in urls) {
		if (paths.length > 0) {
			[paths appendString:@"\n"];
		}

		[paths appendString:[url path]];
	}

	const char *utf8 = [paths UTF8String];
	size_t length = strlen(utf8);

	if (length >= WM_PATHS_MAX) {
		length = WM_PATHS_MAX - 1;
	}

	memcpy(event.paths, utf8, length);

	wm_push(&event);
	return YES;
}
@end

// A window, and what is remembered about it: the objects that make it up are held here so that
// nothing in the system's own hands is what keeps them alive.
@interface WinitWindow : NSObject
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WinitView *view;
@property (nonatomic, strong) WinitDelegate *delegate;
@end

@implementation WinitWindow
@end

static NSMutableArray<id> *wm_windows; // a WinitWindow per slot, or NSNull where the slot is free
static winit_macos_event wm_queue[WM_QUEUE_CAPACITY];
static int wm_queueHead;
static int wm_queueCount;
static BOOL wm_initialized;

static void wm_push(const winit_macos_event *event) {
	// A queue that is full is one the loop has not come back for yet, and what is dropped is the
	// newest rather than the oldest: what a program has not seen yet is in order, and an event it
	// has not seen the beginning of is one it cannot make sense of.
	if (wm_queueCount == WM_QUEUE_CAPACITY) {
		return;
	}

	wm_queue[(wm_queueHead + wm_queueCount) % WM_QUEUE_CAPACITY] = *event;
	wm_queueCount++;
}

static WinitWindow *wm_slot(int handle) {
	if (handle < 1 || handle > WM_MAX_WINDOWS || wm_windows == nil) {
		return nil;
	}

	id slot = wm_windows[handle - 1];
	return [slot isKindOfClass:[WinitWindow class]] ? (WinitWindow *)slot : nil;
}

static void wm_push_mouse(int type, NSEvent *event, WinitView *view) {
	NSPoint point = [view convertPoint:[event locationInWindow] fromView:nil];

	winit_macos_event pushed;
	memset(&pushed, 0, sizeof(pushed));
	pushed.type = type;
	pushed.window = view.handle;
	pushed.x = point.x;
	pushed.y = [view bounds].size.height - point.y;
	pushed.button = (int)[event buttonNumber];
	pushed.modifiers = (unsigned int)[event modifierFlags];

	// How far the pointer moved is not where it ended up: what draws a cursor wants the place, and
	// what turns a view with a mouse wants the distance -- which is the only thing left of a pointer
	// whose cursor has been taken off the screen and held at one point.
	pushed.dx = [event deltaX];
	pushed.dy = [event deltaY];

	wm_push(&pushed);
}

// Whether a key that changed the flags is now held or was just let go, which is what tells a
// press from a release: this platform reports the state of the keyboard rather than the key.
static int wm_modifier_held(unsigned short keycode, NSEventModifierFlags flags) {
	switch (keycode) {
	case WM_KEY_LEFT_SHIFT:
	case WM_KEY_RIGHT_SHIFT:
		return (flags & NSEventModifierFlagShift) != 0;
	case WM_KEY_LEFT_CONTROL:
	case WM_KEY_RIGHT_CONTROL:
		return (flags & NSEventModifierFlagControl) != 0;
	case WM_KEY_LEFT_OPTION:
	case WM_KEY_RIGHT_OPTION:
		return (flags & NSEventModifierFlagOption) != 0;
	case WM_KEY_LEFT_COMMAND:
	case WM_KEY_RIGHT_COMMAND:
		return (flags & NSEventModifierFlagCommand) != 0;
	case WM_KEY_CAPS_LOCK:
		return (flags & NSEventModifierFlagCapsLock) != 0;
	default:
		return -1;
	}
}

// The pointer is held inside the window by putting it back where it left: this platform has no
// grab of its own, only a pointer a program may move.
static void wm_contain_pointer(WinitWindow *slot, NSPoint point, NSSize size) {
	CGFloat x = point.x;
	CGFloat y = point.y;

	if (x >= 0 && x < size.width && y >= 0 && y < size.height) {
		return;
	}

	if (x < 0) x = 0;
	if (y < 0) y = 0;
	if (x > size.width - 1) x = size.width - 1;
	if (y > size.height - 1) y = size.height - 1;

	NSPoint inside = NSMakePoint(x, y);
	NSPoint screen = [slot.window convertPointToScreen:inside];
	CGWarpMouseCursorPosition(CGPointMake(screen.x, [[[NSScreen screens] firstObject] frame].size.height - screen.y));
}

static void wm_handle_event(NSEvent *event) {
	NSWindow *window = [event window];
	id view = window ? [window contentView] : nil;

	if (![view isKindOfClass:[WinitView class]]) {
		[NSApp sendEvent:event];
		return;
	}

	WinitView *winitView = (WinitView *)view;
	WinitWindow *slot = wm_slot(winitView.handle);

	switch ([event type]) {
	case NSEventTypeMouseMoved:
	case NSEventTypeLeftMouseDragged:
	case NSEventTypeRightMouseDragged:
	case NSEventTypeOtherMouseDragged: {
		wm_push_mouse(WM_MOUSE_MOVE, event, winitView);

		if (slot != nil && winitView.grab == WM_GRAB_CONTAIN) {
			wm_contain_pointer(slot, [winitView convertPoint:[event locationInWindow] fromView:nil],
				[winitView bounds].size);
		}

		break;
	}

	case NSEventTypeLeftMouseDown:
	case NSEventTypeRightMouseDown:
	case NSEventTypeOtherMouseDown:
		wm_push_mouse(WM_MOUSE_PRESS, event, winitView);
		break;

	case NSEventTypeLeftMouseUp:
	case NSEventTypeRightMouseUp:
	case NSEventTypeOtherMouseUp:
		wm_push_mouse(WM_MOUSE_RELEASE, event, winitView);
		break;

	case NSEventTypeScrollWheel: {
		// A wheel is counted in lines and a trackpad in points: what a wheel turned by is what a
		// program is told -- one notch one line -- and how far a trackpad moved is what it is told
		// instead. The sign is turned around, since a wheel turned up moves a page up, and the
		// platform counts the turn rather than the move.
		double dx = -[event scrollingDeltaX];
		double dy = -[event scrollingDeltaY];

		if (![event hasPreciseScrollingDeltas]) {
			dx = dx > 0 ? 1 : (dx < 0 ? -1 : 0);
			dy = dy > 0 ? 1 : (dy < 0 ? -1 : 0);
		}

		winit_macos_event pushed;
		memset(&pushed, 0, sizeof(pushed));
		pushed.type = WM_MOUSE_SCROLL;
		pushed.window = winitView.handle;
		pushed.dx = dx;
		pushed.dy = dy;
		pushed.modifiers = (unsigned int)[event modifierFlags];

		wm_push(&pushed);
		break;
	}

	case NSEventTypeKeyDown:
	case NSEventTypeKeyUp: {
		winit_macos_event pushed;
		memset(&pushed, 0, sizeof(pushed));
		pushed.type = [event type] == NSEventTypeKeyDown ? WM_KEY_PRESS : WM_KEY_RELEASE;
		pushed.window = winitView.handle;
		pushed.keycode = [event keyCode];
		pushed.modifiers = (unsigned int)[event modifierFlags];
		pushed.repeated = [event isARepeat] ? 1 : 0;

		NSString *characters = [event characters];

		if (characters != nil) {
			const char *utf8 = [characters UTF8String];

			// What a key types, when it types anything: a key that types more than a handful of
			// bytes at once is one this refuses rather than cuts a character in half over.
			if (utf8 != NULL && strlen(utf8) < WM_TEXT_MAX) {
				memcpy(pushed.text, utf8, strlen(utf8));
			}
		}

		wm_push(&pushed);
		break;
	}

	case NSEventTypeFlagsChanged: {
		int held = wm_modifier_held([event keyCode], [event modifierFlags]);

		if (held >= 0) {
			winit_macos_event pushed;
			memset(&pushed, 0, sizeof(pushed));
			pushed.type = held ? WM_KEY_PRESS : WM_KEY_RELEASE;
			pushed.window = winitView.handle;
			pushed.keycode = [event keyCode];
			pushed.modifiers = (unsigned int)[event modifierFlags];

			wm_push(&pushed);
		}

		break;
	}

	default:
		break;
	}

	// Everything still goes on to the system, which is what makes a window take the keyboard when
	// it is clicked, its title bar drag it, and the menu answer a shortcut. What the system does
	// with a key a program has already been told about is nothing, since a view of this swallows
	// it rather than passing it on.
	[NSApp sendEvent:event];
}

// Makes the program one with a menu bar and a window that can take the keyboard. Nothing is done
// twice, and nothing alive is made here beyond the application's own.
int winit_macos_init(void) {
	if (wm_initialized) {
		return 0;
	}

	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		[NSApp finishLaunching];

		// A program with nowhere to put a window -- one run over ssh into a machine nobody is
		// logged into the screen of -- has no screen to ask about, and saying so is what lets a
		// program with a suite of tests skip them rather than fail them. What is asked is asked
		// after the application is made, since the screens are the window server's and a program
		// that has not reached it yet is one that can see none of them.
		if ([NSScreen screens].count == 0) {
			return -1;
		}

		// The menu is the program's, and what it carries is what a mac program is expected to
		// answer to: without one, the shortcuts every program answers to -- quitting among them --
		// are strokes the keyboard makes and nothing hears.
		NSMenu *menuBar = [[NSMenu alloc] init];
		NSMenuItem *item = [[NSMenuItem alloc] init];
		NSMenu *appMenu = [[NSMenu alloc] init];

		[appMenu addItemWithTitle:[@"Quit " stringByAppendingString:[[NSProcessInfo processInfo] processName]]
			action:@selector(terminate:)
			keyEquivalent:@"q"];
		[item setSubmenu:appMenu];
		[menuBar addItem:item];
		[NSApp setMainMenu:menuBar];
	}

	wm_initialized = YES;
	return 0;
}

// A window of the size a program asked for, which is the size of what it draws in rather than the
// size of the whole thing: the title bar is the system's and is not counted.
int winit_macos_window_create(int width, int height, const char *title) {
	if (winit_macos_init() != 0) {
		return 0;
	}

	if (wm_windows == nil) {
		wm_windows = [[NSMutableArray alloc] initWithCapacity:WM_MAX_WINDOWS];

		for (int i = 0; i < WM_MAX_WINDOWS; i++) {
			[wm_windows addObject:[NSNull null]];
		}
	}

	int handle = 0;

	for (int i = 0; i < WM_MAX_WINDOWS; i++) {
		if ([wm_windows[i] isKindOfClass:[WinitWindow class]]) {
			continue;
		}

		handle = i + 1;
		break;
	}

	if (handle == 0) {
		return 0;
	}

	NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
		| NSWindowStyleMaskResizable;

	@autoreleasepool {
		NSRect rect = NSMakeRect(0, 0, width, height);
		NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
			styleMask:style
			backing:NSBackingStoreBuffered
			defer:NO];

		if (window == nil) {
			return 0;
		}

		// A window that is let go of when it is closed is one this would be holding a corpse of:
		// closing it is what a program asks for, and what it does afterwards is its own.
		[window setReleasedWhenClosed:NO];
		[window setTitle:[NSString stringWithUTF8String:title != NULL ? title : "winit"]];

		WinitView *view = [[WinitView alloc] initWithFrame:rect];
		view.handle = handle;
		view.grab = WM_GRAB_NONE;
		[window setContentView:view];

		WinitDelegate *delegate = [[WinitDelegate alloc] init];
		delegate.handle = handle;
		[window setDelegate:delegate];

		// A window is a place files may be dropped on, which is said rather than assumed: until it
		// is, the system will not let a drag over it end in one.
		[window registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];

		[window makeFirstResponder:view];
		[window center];
		[window makeKeyAndOrderFront:nil];
		[NSApp activateIgnoringOtherApps:YES];

		WinitWindow *slot = [[WinitWindow alloc] init];
		slot.window = window;
		slot.view = view;
		slot.delegate = delegate;
		wm_windows[handle - 1] = slot;
	}

	return handle;
}

void winit_macos_window_destroy(int handle) {
	WinitWindow *slot = wm_slot(handle);

	if (slot == nil) {
		return;
	}

	@autoreleasepool {
		if (slot.view.grab != WM_GRAB_NONE) {
			winit_macos_window_set_grab(handle, WM_GRAB_NONE);
		}

		[slot.window setDelegate:nil];
		[slot.window orderOut:nil];
		[slot.window close];

		wm_windows[handle - 1] = [NSNull null];
	}
}

void winit_macos_window_set_title(int handle, const char *title) {
	WinitWindow *slot = wm_slot(handle);

	if (slot == nil || title == NULL) {
		return;
	}

	@autoreleasepool {
		[slot.window setTitle:[NSString stringWithUTF8String:title]];
	}
}

// What the window draws in, in the points a program counts in -- which is what a program is told
// its size is, rather than the size of the whole thing the title bar is part of.
void winit_macos_window_size(int handle, int *width, int *height) {
	WinitWindow *slot = wm_slot(handle);

	if (slot == nil) {
		return;
	}

	NSRect bounds = [slot.view bounds];

	if (width != NULL) {
		*width = (int)bounds.size.width;
	}

	if (height != NULL) {
		*height = (int)bounds.size.height;
	}
}

// The view a program draws into, which is what a renderer is given to make a context out of. It
// is handed over as a pointer rather than a handle: what is on the other side is another library
// that talks to the system itself.
void *winit_macos_window_view(int handle) {
	WinitWindow *slot = wm_slot(handle);

	return slot != nil ? (__bridge void *)slot.view : NULL;
}

void winit_macos_window_set_cursor(int handle, int shape) {
	(void)handle;

	if (shape == WM_CURSOR_HAND) {
		[[NSCursor pointingHandCursor] set];
	} else {
		[[NSCursor arrowCursor] set];
	}
}

void winit_macos_window_reset_cursor(int handle) {
	(void)handle;
	[[NSCursor arrowCursor] set];
}

// How far the pointer is held: the pointer is hidden and, for a grab that has to keep hearing
// where the mouse goes when the cursor has nowhere left to move, taken off the cursor altogether.
void winit_macos_window_set_grab(int handle, int mode) {
	WinitWindow *slot = wm_slot(handle);

	if (slot == nil) {
		return;
	}

	slot.view.grab = mode;

	if (mode == WM_GRAB_NONE) {
		CGAssociateMouseAndMouseCursorPosition(true);
		CGDisplayShowCursor(kCGDirectMainDisplay);
	} else {
		CGDisplayHideCursor(kCGDirectMainDisplay);

		if (mode == WM_GRAB_LOCKED) {
			CGAssociateMouseAndMouseCursorPosition(false);
		} else {
			CGAssociateMouseAndMouseCursorPosition(true);
		}
	}
}

// The next event, waited for up to a deadline: nothing to wait on at all for a program taking
// what is already there, and no deadline at all for one waiting out an event that may never come.
// A timeout of zero asks whether there is one now, one below zero waits as long as it takes, and
// one above it is how many seconds the wait may last.
int winit_macos_next_event(winit_macos_event *out, double timeout) {
	if (wm_initialized && wm_queueCount == 0) {
		@autoreleasepool {
			NSDate *until = timeout < 0 ? [NSDate distantFuture]
				: (timeout == 0 ? [NSDate distantPast] : [NSDate dateWithTimeIntervalSinceNow:timeout]);

			// What the system has is taken until something a program cares about has happened, or
			// until the deadline passes: an event that is not one is still one that has to be sent
			// on -- a window being moved, a menu opening -- and what it does while it is sent is
			// what turns it into one.
			while (wm_queueCount == 0) {
				NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
					untilDate:until
					inMode:NSDefaultRunLoopMode
					dequeue:YES];

				if (event == nil) {
					break;
				}

				wm_handle_event(event);
				[NSApp updateWindows];
			}
		}
	}

	if (wm_queueCount == 0 || out == NULL) {
		return 0;
	}

	*out = wm_queue[wm_queueHead];
	wm_queueHead = (wm_queueHead + 1) % WM_QUEUE_CAPACITY;
	wm_queueCount--;
	return 1;
}

// What the clipboard holds, as text, handed over in a buffer the caller owns: the length is
// answered whether or not there is room for it, so a caller that has none yet asks once for the
// size and once for the text. A clipboard holding no text at all answers with nothing.
int winit_macos_clipboard_get(char *buffer, int capacity) {
	@autoreleasepool {
		NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];

		if (text == nil) {
			return -1;
		}

		const char *utf8 = [text UTF8String];
		int length = (int)strlen(utf8);

		if (buffer != NULL && capacity > 0) {
			int copied = length < capacity - 1 ? length : capacity - 1;
			memcpy(buffer, utf8, copied);
			buffer[copied] = '\0';
		}

		return length;
	}
}

int winit_macos_clipboard_set(const char *text) {
	if (text == NULL) {
		return 1;
	}

	@autoreleasepool {
		NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
		[pasteboard clearContents];

		return [pasteboard setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString] ? 0 : 1;
	}
}

int winit_macos_clipboard_clear(void) {
	@autoreleasepool {
		[[NSPasteboard generalPasteboard] clearContents];
	}

	return 0;
}
