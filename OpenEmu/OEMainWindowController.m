/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEMainWindowController.h"

#import "OESetupAssistant.h"
#import "OECoreUpdater.h"
#import "OELibraryDatabase.h"

#import "OEGameDocument.h"
@import OpenEmuKit;
#import "OEGameViewController.h"

#import "OEDBGame.h"
#import "OEDBRom.h"

#import "OEROMImporter.h"

#import "NSDocument+OEAdditions.h"

#import "OpenEmu-Swift.h"

NSString *const OEForcePopoutGameWindowKey = @"forcePopout";
NSString *const OEFullScreenGameWindowKey  = @"fullScreen";

NSString *const OEMainWindowIdentifier     = @"LibraryWindow";
NSString *const OEDefaultWindowTitle       = @"OpenEmu";

#define MainMenu_Window_OpenEmuTag 501

@interface OEMainWindowController () <OELibraryControllerDelegate>
{
    OEGameDocument *_gameDocument;
    BOOL            _shouldExitFullScreenWhenGameFinishes;
    BOOL            _shouldUndockGameWindowOnFullScreenExit;
    BOOL            _resumePlayingAfterFullScreenTransition;
    
    BOOL _isLaunchingGame;
    
    NSLayoutConstraint *_lastPlaceholderViewTopConstraint;
}

@end

@implementation OEMainWindowController

- (void)dealloc
{
    _currentContentController = nil;
    [self setDefaultContentController:nil];
    [self setLibraryController:nil];
    [self setPlaceholderView:nil];
}

- (id)initWithWindow:(NSWindow *)window
{
    if((self = [super initWithWindow:window]) == nil)
        return nil;
    
    // Since restoration from autosave happens before NSWindowController
    // receives -windowDidLoad and we are autosaving the window size, we
    // need to set allowWindowResizing to YES before -windowDidLoad
    _allowWindowResizing = YES;
    
    return self;
}


- (void)awakeFromNib
{
    [super awakeFromNib];
    
    [self setUpPlaceholderView];
    [self setUpLibraryController];
    [self setUpWindow];
    [self setUpCurrentContentController];
    [self setUpViewMenuItemBindings];
    
    _isLaunchingGame = NO;
}

- (void)setUpPlaceholderView
{
    self.placeholderView.translatesAutoresizingMaskIntoConstraints = NO;
    
    NSLayoutGuide *windowGuide = self.window.contentLayoutGuide;
    _lastPlaceholderViewTopConstraint =
        [windowGuide.topAnchor constraintEqualToAnchor:self.placeholderView.topAnchor];
        
    [NSLayoutConstraint activateConstraints:@[
        [windowGuide.leftAnchor constraintEqualToAnchor:self.placeholderView.leftAnchor],
        [windowGuide.bottomAnchor constraintEqualToAnchor:self.placeholderView.bottomAnchor],
        [windowGuide.rightAnchor constraintEqualToAnchor:self.placeholderView.rightAnchor],
        _lastPlaceholderViewTopConstraint
    ]];
}

- (void)setUpLibraryController
{
    OELibraryController *libraryController = self.libraryController;
    
    libraryController.delegate = self;
    
    [libraryController view];
    self.window.toolbar = libraryController.toolbar;
    self.window.toolbar.centeredItemIdentifier = @"OEToolbarCategoryItem";
    
    if (@available(macOS 11.0, *)) {
        self.window.toolbarStyle = NSWindowToolbarStyleUnified;
        self.window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleLine;
    }
}

- (void)setUpWindow
{
    NSWindow *window = self.window;
    
    window.delegate = self;
    window.excludedFromWindowsMenu = YES;
    window.restorationClass = [self class];
    window.backgroundColor = NSColor.controlBackgroundColor;
    
    NSAssert([window.identifier isEqualToString:OEMainWindowIdentifier], @"Main library window identifier does not match between nib and code");
}

- (void)setUpCurrentContentController
{
    if(![[NSUserDefaults standardUserDefaults] boolForKey:OESetupAssistantHasFinishedKey])
    {
        OESetupAssistant *setupAssistant = [[OESetupAssistant alloc] init];
        [setupAssistant setCompletionBlock:^{
            [self setCurrentContentController:self.libraryController];
            
            // Reload sidebar to make systems show up // FIXME: 
            [NSNotificationCenter.defaultCenter postNotificationName:OELibraryLocationDidChangeNotification object:nil];
        }];
        
        [self.window center];
        
        [self setCurrentContentController:setupAssistant];
    }
    else
    {
        [self setCurrentContentController:self.libraryController];
    }
}

- (void)setUpViewMenuItemBindings
{
    NSMenu *viewMenu = [[[NSApp mainMenu] itemAtIndex:3] submenu];
    NSMenuItem *showLibraryNames = [viewMenu itemWithTag:10];
    NSMenuItem *showRomNames     = [viewMenu itemWithTag:11];
    NSMenuItem *undockGameWindow = [viewMenu itemWithTag:3];
    
    NSDictionary *negateOptions = @{NSValueTransformerNameBindingOption:NSNegateBooleanTransformerName};
    [showLibraryNames bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:negateOptions];
    [showRomNames     bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:negateOptions];
    [undockGameWindow bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:@{}];
}

- (NSString *)windowNibName
{
    return @"MainWindow";
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    
    NSWindow *window = self.window;
    window.title = OEDefaultWindowTitle;
#if DEBUG_PRINT
    window.title = [window.title stringByAppendingString:@" (DEBUG BUILD)"];
#endif
}

#pragma mark -
// ugly hack, remove
- (void)startGame:(OEDBGame*)game
{
    [self OE_openGameDocumentWithGame:game saveState:[game autosaveForLastPlayedRom]];
}

#pragma mark -

- (void)setCurrentContentController:(NSViewController *)newController
{
    if(newController == nil) newController = self.libraryController;
    if(newController == self.currentContentController) return;
    
    NSView *placeHolderView = self.placeholderView;
    NSWindow *window = self.window;
    
    [self->_currentContentController viewWillDisappear];
    [newController view];
    [newController viewWillAppear];

    NSView *viewToReplace = _currentContentController.view;
    
    if(viewToReplace)
        [viewToReplace removeFromSuperview];
    [self->_currentContentController viewDidDisappear];
    
    // Adjust visual properties of the window.
    
    // HACK: toolbar.allowsUserCustomization=NO prevents re-enabling the toolbar
    // by right clicking on the title bar.
    // The correct fix would be to set window.toolbar to nil, but because the
    // toolbar is instantiated from InterfaceBuilder setting the toolbar to nil
    // also deallocates the toolbar...
    // Changing the toolbar to be instantiated in code causes the items to
    // be loaded too late, and it would require basically a rewrite of the
    // toolbar handling code... :/
    // TODO: fix toolbar handling code to remove the hack
    
    BOOL overlapsTitleBar = NO;
    if (newController == _gameDocument.gameViewController) {
        window.toolbar.visible = NO;
        window.toolbar.allowsUserCustomization = NO;
        window.titleVisibility = NSWindowTitleVisible;
        window.titlebarAppearsTransparent = NO;
        overlapsTitleBar = NO;
        
    } else if (newController == self.libraryController) {
        window.toolbar.visible = YES;
        if (@available(macOS 10.15.0, *)) {
            window.toolbar.allowsUserCustomization = YES;
        } else {
            /* avoids a crash on 10.14.
             * TODO: remove when 10.14 support goes away */
            window.toolbar.allowsUserCustomization = NO;
        }
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = NO;
        window.styleMask |= NSWindowStyleMaskClosable;
        overlapsTitleBar = YES;
        
    } else if ([newController isKindOfClass:[OESetupAssistant class]]) {
        window.toolbar.visible = NO;
        window.toolbar.allowsUserCustomization = NO;
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        window.styleMask &= ~NSWindowStyleMaskClosable;
        overlapsTitleBar = YES;
        
    } else {
        // probably unused
        window.titleVisibility = NSWindowTitleHidden;
    }
    
    // Set the size of the new controller *before* it is added to the
    // view hierarchy. This is important because things like NSSplitter
    // sizes are loaded as soon as the view is added to a subview.
    newController.view.frame = placeHolderView.bounds;
    newController.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [placeHolderView addSubview:newController.view];
    
    NSLayoutGuide *windowGuide = self.window.contentLayoutGuide;
    _lastPlaceholderViewTopConstraint.active = NO;
    _lastPlaceholderViewTopConstraint = overlapsTitleBar ?
        [self.placeholderView.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor] :
        [self.placeholderView.topAnchor constraintEqualToAnchor:windowGuide.topAnchor];
    _lastPlaceholderViewTopConstraint.active = YES;

    [window makeFirstResponder:newController.view];
    
    _currentContentController = newController;
    if (newController == _gameDocument.gameViewController) {
        _gameDocument.gameWindowController = self;
    }
    
    [newController viewDidAppear];
    
    // If a game is playing in the library window, unpause emulation immediately.
    if (newController == _gameDocument.gameViewController) {
        _gameDocument.emulationPaused = NO;
    }
}

- (IBAction)undockGameWindow:(id)sender
{
    _mainWindowRunsGame = NO;
    
    if(_shouldExitFullScreenWhenGameFinishes && [[self window] isFullScreen])
    {
        [[self window] toggleFullScreen:self];
        _shouldExitFullScreenWhenGameFinishes = NO;
        _shouldUndockGameWindowOnFullScreenExit = YES;
    }
    else
    {
        [_gameDocument setEmulationPaused:YES];
        [self setCurrentContentController:nil];
        [_gameDocument setGameWindowController:nil];
        
        [_gameDocument showInSeparateWindowInFullScreen:NO];
        _gameDocument = nil;
    }
}

#pragma mark - OELibraryControllerDelegate protocol conformance

- (void)OE_openGameDocumentWithGame:(OEDBGame *)game saveState:(OEDBSaveState *)state
{
    [self OE_openGameDocumentWithGame:game saveState:state secondAttempt:NO disableAutoReload:NO];
}

- (void)OE_openGameDocumentWithGame:(OEDBGame *)game saveState:(OEDBSaveState *)state secondAttempt:(BOOL)retry disableAutoReload:(BOOL)noAutoReload API_DEPRECATED("Remove \"User Reports\" from alert (~line 413), that term is not used in Catalina and above", macos(10.0, 10.15));

{
    // make sure we don't launch a game multiple times :/
    if(_isLaunchingGame) return;
    _isLaunchingGame = YES;
    
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    BOOL openInSeparateWindow = _mainWindowRunsGame || [standardDefaults boolForKey:OEForcePopoutGameWindowKey];
    BOOL fullScreen = [standardDefaults boolForKey:OEFullScreenGameWindowKey];
    
    BOOL openWithSaveState = state != nil;
    if (!noAutoReload) {
        openWithSaveState = openWithSaveState || ((state=[game autosaveForLastPlayedRom]) && [[OEAlert loadAutoSaveGameAlert] runModal] == NSAlertFirstButtonReturn);
    }
    
    _shouldExitFullScreenWhenGameFinishes = NO;
    void (^openDocument)(OEGameDocument *, NSError *) =
    ^(OEGameDocument *document, NSError *error)
    {
        self->_isLaunchingGame = NO;
        if(document == nil)
        {
            if([[error domain] isEqualToString:OEGameDocumentErrorDomain] && [error code] == OEFileDoesNotExistError && game)
            {
                [game setStatus:@(OEDBGameStatusAlert)];
                [game save];
                
                NSString *messageText = [NSString stringWithFormat:NSLocalizedString(@"The game '%@' could not be started because a rom file could not be found. Do you want to locate it?", @""), [game name]];
                OEAlert *alert = [[OEAlert alloc] init];
                alert.messageText = messageText;
                alert.defaultButtonTitle = NSLocalizedString(@"Locate…", @"");
                alert.alternateButtonTitle = NSLocalizedString(@"Cancel", @"");
                if([alert runModal] == NSAlertFirstButtonReturn)
                {
                    OEDBRom  *missingRom = [[game roms] anyObject];
                    NSURL   *originalURL = [missingRom URL];
                    NSString  *extension = [originalURL pathExtension];
                    
                    NSString *panelTitle = [NSString stringWithFormat:NSLocalizedString(@"Locate '%@'", @"Locate panel title"), [[originalURL pathComponents] lastObject]];
                    NSOpenPanel  *panel = [NSOpenPanel openPanel];
                    [panel setMessage:panelTitle];
                    [panel setCanChooseDirectories:NO];
                    [panel setCanChooseFiles:YES];
                    [panel setDirectoryURL:[originalURL URLByDeletingLastPathComponent]];
                    [panel setAllowsOtherFileTypes:NO];
                    [panel setAllowedFileTypes:@[extension]];
                    
                    if([panel runModal] == NSModalResponseOK)
                    {
                        [missingRom setURL:[panel URL]];
                        [missingRom save];
                        [self OE_openGameDocumentWithGame:game saveState:state];
                    }
                }
            }
            // FIXME: make it possible to locate missing rom files when the game is started from a savestate
            else if([[error domain] isEqualToString:OEGameDocumentErrorDomain] && [error code] == OEFileDoesNotExistError && !game)
            {
                NSString *messageText = NSLocalizedString(@"The game '%@' could not be started because a rom file could not be found. Do you want to locate it?", @"");
                
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[\"'“„« ]+%@[\"'”“» ]+[ を]?" options:NSRegularExpressionCaseInsensitive error:NULL];
                messageText = [regex stringByReplacingMatchesInString:messageText options:0 range:NSMakeRange(0, messageText.length) withTemplate:@""];
                
                NSRange range = [messageText rangeOfString:@"."];
                if (range.location == NSNotFound)
                    range = [messageText rangeOfString:@"。"];
                if (range.location != NSNotFound)
                    messageText = [messageText substringToIndex:range.location+1];
                
                messageText = [messageText stringByAppendingString:NSLocalizedString(@" Start the game from the library view if you want to locate it.", @"")];
                OEAlert *alert = [[OEAlert alloc] init];
                alert.messageText = messageText;
                alert.defaultButtonTitle = NSLocalizedString(@"OK", @"");
                [alert runModal];
            }
            else if ([error.domain isEqual:OEGameDocumentErrorDomain] && error.code == OENoCoreError && !retry) {
                // Try downloading the core list before bailing out definitively
                OEAlert *modalAlert = [[OEAlert alloc] init];
                modalAlert.messageText = NSLocalizedString(@"Downloading core list...", @"");
                modalAlert.defaultButtonTitle = NSLocalizedString(@"Cancel", @"");
                [modalAlert performBlockInModalSession:^{
                    [OECoreUpdater.sharedUpdater checkForNewCoresWithCompletionHandler:^(NSError * _Nonnull error) {
                        [modalAlert closeWithResult:NSAlertSecondButtonReturn];
                    }];
                }];
                NSModalResponse alertCode = [modalAlert runModal];
                if (alertCode == NSAlertFirstButtonReturn) {
                    // user says no
                    [OECoreUpdater.sharedUpdater cancelCheckForNewCores];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self presentError:error];
                    });
                } else {
                    // let's give it another try
                    [self OE_openGameDocumentWithGame:game saveState:state secondAttempt:YES disableAutoReload:NO];
                }
            }
            else if ([error.domain isEqual:OEGameDocumentErrorDomain] && error.code == OEGameCoreCrashedError) {
                // TODO: the setup completion handler shouldn't be the place where non-setup-related errors are handled!
                OECorePlugin *core = error.userInfo[@"corePlugin"];
                NSString *coreName = core.displayName;
                BOOL glitchy = [core.controller hasGlitchesForSystemIdentifier:error.userInfo[@"systemIdentifier"]];
                
                OEAlert *alert = [[OEAlert alloc] init];
                if (openWithSaveState) {
                    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"The %@ core has quit unexpectedly after loading a save state", @""), coreName];
                    alert.informativeText = NSLocalizedString(@"Sometimes a crash may occur while loading a save state because of incompatibilities between different versions of the same core. Do you want to open the game without loading a save state?", @"");
                    alert.defaultButtonTitle = NSLocalizedString(@"Reopen without loading state", @"");
                    alert.alternateButtonTitle = NSLocalizedString(@"Cancel", @"");
                    NSModalResponse resp = [alert runModal];
                    if (resp == NSAlertFirstButtonReturn)
                        [self OE_openGameDocumentWithGame:state.rom.game saveState:nil secondAttempt:YES disableAutoReload:YES];
                } else {
                    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"The %@ core has quit unexpectedly", @""), coreName];
                    if (glitchy) {
                        alert.informativeText = [NSString stringWithFormat:NSLocalizedString(@"The %@ core has compatibility issues and some games may contain glitches or not play at all.\n\nPlease do not report problems as we are not responsible for the development of %@.", @""), coreName, coreName];
                    } else {
                        alert.informativeText = NSLocalizedString(
                            @"<b>If and only if this issue persists</b>, please submit feedback including:<br><br>"
                            @"<ul>"
                            @"<li>The model of Mac you are using <b>and</b> the version of macOS you have installed"
                                @"<ul><li>This information is found in  > About this Mac</li></ul></li>"
                            @"<li>The <b>exact name</b> of the game you were playing</li>"
                            @"<li>The crash report of OpenEmuHelperApp"
                                @"<ul><li>Open Console.app, click on \"Crash Reports\" or \"User Reports\" in the sidebar, "
                                @"then look for the latest document with OpenEmuHelperApp in the name</ul></li></li>"
                            @"</ul><br>"
                            @"<b>Always search for similar feedback previously reported by other users!</b><br>"
                            @"If any of this information is omitted, or if similar feedback has already been issued, your issue report may be closed.", @"Suggestion for crashed cores (HTML). Localizers: specify the report must be written in English");
                        alert.messageUsesHTML = YES;
                    }
                    alert.defaultButtonTitle = NSLocalizedString(@"OK", @"");
                    [alert runModal];
                }
            }
            else if(error && !([error.domain isEqual:NSCocoaErrorDomain] && error.code == NSUserCancelledError)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self presentError:error];
                });
            }
            
            return;
        }
        else if ([[game status] intValue] == OEDBGameStatusAlert)
        {
            [game setStatus:@(OEDBGameStatusOK)];
            [game save];
        }
        
        if(openInSeparateWindow) return;
        
        self->_shouldExitFullScreenWhenGameFinishes = ![[self window] isFullScreen];
        self->_gameDocument = document;
        self->_mainWindowRunsGame = YES;
        
        while([[[self window] titlebarAccessoryViewControllers] count])
            [[self window] removeTitlebarAccessoryViewControllerAtIndex:0];
        [[[self window] toolbar] setVisible:NO];
        
        if(fullScreen && ![[self window] isFullScreen])
        {
            [NSApp activateIgnoringOtherApps:YES];
            
            [self setCurrentContentController:[document gameViewController]];
            [document setEmulationPaused:NO];
            [[self window] toggleFullScreen:self];
        }
        else
        {
            [document setGameWindowController:self];
            [self setCurrentContentController:[document gameViewController]];
        }
    };
    
    if (openWithSaveState)
        [[NSDocumentController sharedDocumentController] openGameDocumentWithSaveState:state display:openInSeparateWindow fullScreen:fullScreen completionHandler:openDocument];
    else
        [[NSDocumentController sharedDocumentController] openGameDocumentWithGame:game display:openInSeparateWindow fullScreen:fullScreen completionHandler:openDocument];
}

- (void)libraryController:(OELibraryController *)sender didSelectGame:(OEDBGame *)game
{
    [self OE_openGameDocumentWithGame:game saveState:nil];
}

- (void)libraryController:(OELibraryController *)sender didSelectSaveState:(OEDBSaveState *)saveState
{
    [self OE_openGameDocumentWithGame:nil saveState:saveState];
}

#pragma mark - NSWindow delegate

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
    return [self allowWindowResizing] ? frameSize : [sender frame].size;
}

- (BOOL)windowShouldClose:(id)sender
{
    if([self currentContentController] == [self libraryController])
        return YES;
    else
    {
        [_gameDocument canCloseDocumentWithCompletionHandler:
         ^(NSDocument *document, BOOL shouldClose)
         {
             [self->_gameDocument setGameWindowController:nil];
             [self->_gameDocument close];
             self->_gameDocument = nil;
             self->_mainWindowRunsGame = NO;
             
             BOOL exitFullScreen = (self->_shouldExitFullScreenWhenGameFinishes && [[self window] isFullScreen]);
             if(exitFullScreen)
             {
                 [[[self window] toolbar] setVisible:YES];
                 [[self window] toggleFullScreen:self];
                 self->_shouldExitFullScreenWhenGameFinishes = NO;
             }
             
             [self setCurrentContentController:nil];
         }];
        
        return NO;
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    // Make sure the current content controller gets viewWillDisappear / viewDidAppear so it has a chance to store its state
    if([self currentContentController] == [self libraryController])
    {
        [[self libraryController] viewWillDisappear];
        [[self libraryController] viewDidDisappear];
        [[self libraryController] viewWillAppear];
        [[self libraryController] viewDidAppear];
    }
    
    [self setCurrentContentController:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    [[self currentContentController] viewWillAppear];
    [[self currentContentController] viewDidAppear];
}

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSApp mainMenu];
    
    NSMenu *windowMenu = [[mainMenu itemAtIndex:5] submenu];
    NSMenuItem *item = [windowMenu itemWithTag:MainMenu_Window_OpenEmuTag];
    [item setState:NSControlStateValueOn];
}

- (void)windowDidResignMain:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSApp mainMenu];
    
    NSMenu *windowMenu = [[mainMenu itemAtIndex:5] submenu];
    NSMenuItem *item = [windowMenu itemWithTag:MainMenu_Window_OpenEmuTag];
    [item setState:NSControlStateValueOff];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    if(_gameDocument && [_gameDocument gameWindowController] == self)
    {
        _resumePlayingAfterFullScreenTransition = ![_gameDocument isEmulationPaused];
        [_gameDocument setEmulationPaused:YES];
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    if(_gameDocument == nil) {
        return;
    }
    
    if(_shouldExitFullScreenWhenGameFinishes)
    {
        [_gameDocument setGameWindowController:self];
        [self setCurrentContentController:[_gameDocument gameViewController]];
    }
    
    if(_resumePlayingAfterFullScreenTransition)
        [_gameDocument setEmulationPaused:NO];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    if(_gameDocument)
    {
        _resumePlayingAfterFullScreenTransition = ![_gameDocument isEmulationPaused];
        [_gameDocument setEmulationPaused:YES];
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    if(_shouldUndockGameWindowOnFullScreenExit)
    {
        _shouldUndockGameWindowOnFullScreenExit = NO;
        
        [self setCurrentContentController:nil];
        
        [_gameDocument showInSeparateWindowInFullScreen:NO];
        
        if(_resumePlayingAfterFullScreenTransition)
            [_gameDocument setEmulationPaused:NO];
        
        _gameDocument = nil;
        _mainWindowRunsGame = NO;
    }
    else if(_gameDocument && _resumePlayingAfterFullScreenTransition)
        [_gameDocument setEmulationPaused:NO];
}

#pragma mark - Window Restoration

+ (void)restoreWindowWithIdentifier:(NSString *)identifier state:(NSCoder *)state completionHandler:(void (^)(NSWindow * __nullable, NSError * __nullable))completionHandler
{
    if ([identifier isEqualToString:OEMainWindowIdentifier]) {
        OEApplicationDelegate *appDelegate = (OEApplicationDelegate *)[NSApp delegate];
        
        if (appDelegate) {
            [NSApp extendStateRestoration];
            appDelegate.restoreWindow = YES;
            
            NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
            NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
            void (^completionHandlerCopy)(NSWindow * __nullable, NSError * __nullable) = [completionHandler copy];
            
            id observerOfLibraryDidLoad = [notificationCenter addObserverForName:OELibraryDidLoadNotificationName object:nil queue:mainQueue usingBlock:^(NSNotification * _Nonnull note) {
                OEMainWindowController *mainWindowController = [[self alloc]  initWithWindowNibName:@"MainWindow"];
                appDelegate.mainWindowController = mainWindowController;
                NSWindow *mainWindow = [mainWindowController window];
                
                completionHandlerCopy(mainWindow, nil);
                
                [NSApp completeStateRestoration];
            }];
            
            appDelegate.libraryDidLoadObserverForRestoreWindow = observerOfLibraryDidLoad;
            return;
        }
    }
    completionHandler(nil, nil);
}

#pragma mark - Menu Items

- (IBAction)launchLastPlayedROM:(id)sender
{
    OEDBGame *game = [[sender representedObject] game];
    
    [self OE_openGameDocumentWithGame:game saveState:nil];
}

@end
