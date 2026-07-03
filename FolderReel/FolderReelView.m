//
//  FolderReelView.m
//  FolderReel
//
//  Created by Gold on 03/07/2026.
//

#import "FolderReelView.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, FRPlaybackMode) {
    FRPlaybackModeSequence = 0,
    FRPlaybackModeRandom = 1,
    FRPlaybackModeSingle = 2,
};

static NSString * const FRPlaybackModeKey = @"playbackMode";
static NSString * const FRFolderPathKey = @"folderPath";
static NSString * const FRFolderBookmarkKey = @"folderBookmark";
static NSString * const FRSingleVideoPathKey = @"singleVideoPath";
static NSString * const FRSingleVideoBookmarkKey = @"singleVideoBookmark";
static NSString * const FRSettingsDidChangeNotification = @"FolderReelSettingsDidChangeNotification";

static NSString *FRModuleIdentifier(void)
{
    NSString *identifier = [[NSBundle bundleForClass:FolderReelView.class] bundleIdentifier];
    return identifier.length > 0 ? identifier : @"com.pengfei.FolderReel";
}

static ScreenSaverDefaults *FRDefaults(void)
{
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:FRModuleIdentifier()];
    [defaults registerDefaults:@{ FRPlaybackModeKey: @"sequence" }];
    return defaults;
}

static NSString *FRStringForPlaybackMode(FRPlaybackMode mode)
{
    switch (mode) {
        case FRPlaybackModeRandom:
            return @"random";
        case FRPlaybackModeSingle:
            return @"single";
        case FRPlaybackModeSequence:
        default:
            return @"sequence";
    }
}

static FRPlaybackMode FRPlaybackModeFromString(NSString *value)
{
    if ([value isEqualToString:@"random"]) {
        return FRPlaybackModeRandom;
    }
    if ([value isEqualToString:@"single"]) {
        return FRPlaybackModeSingle;
    }
    return FRPlaybackModeSequence;
}

static NSSet<NSString *> *FRSupportedVideoExtensions(void)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[ @"mp4", @"mov", @"m4v" ]];
    });
    return extensions;
}

static NSString *FRNormalizedPathForURL(NSURL *url)
{
    return url.URLByStandardizingPath.path ?: @"";
}

static BOOL FRURLsMatch(NSURL *left, NSURL *right)
{
    return [FRNormalizedPathForURL(left) isEqualToString:FRNormalizedPathForURL(right)];
}

static NSURL *FRStoredURL(NSString *bookmarkKey, NSString *pathKey)
{
    ScreenSaverDefaults *defaults = FRDefaults();
    NSData *bookmark = [defaults objectForKey:bookmarkKey];
    if ([bookmark isKindOfClass:NSData.class] && bookmark.length > 0) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:NSURLBookmarkResolutionWithSecurityScope
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:&error];
        if (url && !stale) {
            return url;
        }
    }

    NSString *path = [defaults stringForKey:pathKey];
    if (path.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}

static void FRStoreURL(NSURL *url, NSString *bookmarkKey, NSString *pathKey)
{
    ScreenSaverDefaults *defaults = FRDefaults();
    if (url) {
        NSError *error = nil;
        NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                         includingResourceValuesForKeys:nil
                                          relativeToURL:nil
                                                  error:&error];
        if (bookmark.length > 0) {
            [defaults setObject:bookmark forKey:bookmarkKey];
        } else {
            [defaults removeObjectForKey:bookmarkKey];
        }
        [defaults setObject:url.path forKey:pathKey];
    } else {
        [defaults removeObjectForKey:bookmarkKey];
        [defaults removeObjectForKey:pathKey];
    }
    [defaults synchronize];
}

static NSArray<NSURL *> *FRVideoURLsInFolder(NSURL *folderURL)
{
    if (!folderURL.isFileURL) {
        return @[];
    }

    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:folderURL.path isDirectory:&isDirectory] || !isDirectory) {
        return @[];
    }

    NSError *error = nil;
    NSArray<NSURLResourceKey> *keys = @[ NSURLIsRegularFileKey, NSURLLocalizedNameKey ];
    NSArray<NSURL *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:folderURL
                                                               includingPropertiesForKeys:keys
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                    error:&error];
    if (!children) {
        return @[];
    }

    NSMutableArray<NSURL *> *videos = [NSMutableArray array];
    NSSet<NSString *> *extensions = FRSupportedVideoExtensions();
    for (NSURL *url in children) {
        NSNumber *isRegular = nil;
        [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil];
        if (!isRegular.boolValue) {
            continue;
        }

        NSString *extension = url.pathExtension.lowercaseString;
        if ([extensions containsObject:extension]) {
            [videos addObject:url];
        }
    }

    [videos sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
    }];
    return videos.copy;
}

static NSInteger FRIndexOfURLInVideos(NSURL *url, NSArray<NSURL *> *videos)
{
    if (!url) {
        return NSNotFound;
    }

    for (NSUInteger index = 0; index < videos.count; index++) {
        if (FRURLsMatch(url, videos[index])) {
            return (NSInteger)index;
        }
    }
    return NSNotFound;
}

static void FRShuffleMutableArray(NSMutableArray<NSURL *> *array)
{
    if (array.count < 2) {
        return;
    }

    for (NSUInteger index = array.count - 1; index > 0; index--) {
        NSUInteger swapIndex = (NSUInteger)SSRandomIntBetween(0, (int)index);
        [array exchangeObjectAtIndex:index withObjectAtIndex:swapIndex];
    }
}

@interface FRVideoPreviewView : NSView
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) CATextLayer *messageLayer;
- (void)setPreviewPlayer:(AVPlayer *)player;
- (void)showMessage:(NSString *)message;
@end

@implementation FRVideoPreviewView

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.cornerRadius = 6.0;
        self.layer.masksToBounds = YES;

        self.playerLayer = [AVPlayerLayer layer];
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        self.playerLayer.hidden = YES;
        [self.layer addSublayer:self.playerLayer];

        self.messageLayer = [CATextLayer layer];
        self.messageLayer.alignmentMode = kCAAlignmentCenter;
        self.messageLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        self.messageLayer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
        self.messageLayer.wrapped = YES;
        self.messageLayer.fontSize = 13.0;
        [self.layer addSublayer:self.messageLayer];

        [self showMessage:@"Select a video to preview."];
    }
    return self;
}

- (void)layout
{
    [super layout];
    self.playerLayer.frame = self.bounds;
    CGFloat inset = 18.0;
    self.messageLayer.frame = CGRectIntegral(CGRectInset(self.bounds, inset, inset));
}

- (void)setPreviewPlayer:(AVPlayer *)player
{
    self.playerLayer.player = player;
    self.playerLayer.hidden = player == nil;
    self.messageLayer.hidden = player != nil;
}

- (void)showMessage:(NSString *)message
{
    self.playerLayer.player = nil;
    self.playerLayer.hidden = YES;
    self.messageLayer.string = message ?: @"";
    self.messageLayer.hidden = message.length == 0;
}

@end

@interface FRConfigurationController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSTextField *folderField;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) FRVideoPreviewView *previewView;
@property (nonatomic, strong) AVPlayer *previewPlayer;
@property (nonatomic, strong) AVPlayerItem *previewObservedItem;
@property (nonatomic, copy) NSArray<NSURL *> *videoURLs;
@property (nonatomic, strong) NSURL *selectedFolderURL;
@property (nonatomic, strong) NSURL *selectedSingleVideoURL;
@property (nonatomic, assign) NSInteger lastMarkedRow;
@end

@implementation FRConfigurationController

- (instancetype)init
{
    self = [super init];
    if (self) {
        ScreenSaverDefaults *defaults = FRDefaults();
        _selectedFolderURL = FRStoredURL(FRFolderBookmarkKey, FRFolderPathKey);
        _selectedSingleVideoURL = FRStoredURL(FRSingleVideoBookmarkKey, FRSingleVideoPathKey);
        _videoURLs = _selectedFolderURL ? FRVideoURLsInFolder(_selectedFolderURL) : @[];
        _lastMarkedRow = NSNotFound;
        _window = [self buildWindowWithPlaybackMode:FRPlaybackModeFromString([defaults stringForKey:FRPlaybackModeKey])];
        [self refreshFolderStateSelectingStoredVideo:YES];
    }
    return self;
}

- (void)dealloc
{
    [self stopPreview];
}

- (NSWindow *)buildWindowWithPlaybackMode:(FRPlaybackMode)mode
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 780, 500)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"FolderReel Options";

    NSView *contentView = window.contentView;
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14.0;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor],
    ]];

    NSStackView *folderRow = [self horizontalStack];
    NSTextField *folderLabel = [NSTextField labelWithString:@"Folder:"];
    folderLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    self.folderField = [NSTextField labelWithString:@""];
    self.folderField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.folderField.textColor = NSColor.secondaryLabelColor;
    NSButton *chooseButton = [NSButton buttonWithTitle:@"Choose..."
                                                target:self
                                                action:@selector(chooseFolder:)];
    [folderRow addArrangedSubview:folderLabel];
    [folderRow addArrangedSubview:self.folderField];
    [folderRow addArrangedSubview:chooseButton];
    [self.folderField.widthAnchor constraintGreaterThanOrEqualToConstant:540.0].active = YES;
    [stack addArrangedSubview:folderRow];

    NSStackView *modeRow = [self horizontalStack];
    NSTextField *modeLabel = [NSTextField labelWithString:@"Mode:"];
    modeLabel.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium];
    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.modePopup addItemWithTitle:@"Sequential Loop"];
    self.modePopup.lastItem.tag = FRPlaybackModeSequence;
    [self.modePopup addItemWithTitle:@"Random Loop"];
    self.modePopup.lastItem.tag = FRPlaybackModeRandom;
    [self.modePopup addItemWithTitle:@"Single Video Loop"];
    self.modePopup.lastItem.tag = FRPlaybackModeSingle;
    [self.modePopup selectItemWithTag:mode];
    [modeRow addArrangedSubview:modeLabel];
    [modeRow addArrangedSubview:self.modePopup];
    [stack addArrangedSubview:modeRow];

    NSStackView *browserRow = [self horizontalStack];
    browserRow.alignment = NSLayoutAttributeTop;

    NSStackView *listStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    listStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    listStack.alignment = NSLayoutAttributeLeading;
    listStack.spacing = 8.0;
    NSTextField *tableLabel = [NSTextField labelWithString:@"Videos:"];
    tableLabel.textColor = NSColor.secondaryLabelColor;
    [listStack addArrangedSubview:tableLabel];

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.headerView = nil;
    self.tableView.rowHeight = 30.0;
    self.tableView.allowsEmptySelection = NO;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"video"];
    column.title = @"Video";
    column.width = 340.0;
    [self.tableView addTableColumn:column];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.documentView = self.tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    [scrollView.heightAnchor constraintEqualToConstant:250.0].active = YES;
    [scrollView.widthAnchor constraintEqualToConstant:340.0].active = YES;
    [listStack addArrangedSubview:scrollView];

    NSStackView *previewStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    previewStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    previewStack.alignment = NSLayoutAttributeLeading;
    previewStack.spacing = 8.0;
    NSTextField *previewLabel = [NSTextField labelWithString:@"Preview:"];
    previewLabel.textColor = NSColor.secondaryLabelColor;
    [previewStack addArrangedSubview:previewLabel];

    self.previewView = [[FRVideoPreviewView alloc] initWithFrame:NSZeroRect];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewView.widthAnchor constraintEqualToConstant:360.0].active = YES;
    [self.previewView.heightAnchor constraintEqualToConstant:250.0].active = YES;
    [previewStack addArrangedSubview:self.previewView];

    [browserRow addArrangedSubview:listStack];
    [browserRow addArrangedSubview:previewStack];
    [stack addArrangedSubview:browserRow];

    self.statusField = [NSTextField labelWithString:@""];
    self.statusField.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:self.statusField];

    NSStackView *buttonRow = [self horizontalStack];
    buttonRow.alignment = NSLayoutAttributeCenterY;
    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel"
                                                target:self
                                                action:@selector(cancel:)];
    NSButton *saveButton = [NSButton buttonWithTitle:@"Save"
                                              target:self
                                              action:@selector(save:)];
    saveButton.keyEquivalent = @"\r";
    [buttonRow addArrangedSubview:spacer];
    [buttonRow addArrangedSubview:cancelButton];
    [buttonRow addArrangedSubview:saveButton];
    [buttonRow.widthAnchor constraintEqualToConstant:740.0].active = YES;
    [stack addArrangedSubview:buttonRow];

    return window;
}

- (NSStackView *)horizontalStack
{
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 10.0;
    return stack;
}

- (void)chooseFolder:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Choose";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) {
            return;
        }

        self.selectedFolderURL = panel.URL;
        self.selectedSingleVideoURL = nil;
        [self refreshFolderStateSelectingStoredVideo:NO];
    }];
}

- (void)refreshFolderStateSelectingStoredVideo:(BOOL)selectStoredVideo
{
    if (self.selectedFolderURL) {
        self.folderField.stringValue = self.selectedFolderURL.path;
        self.videoURLs = FRVideoURLsInFolder(self.selectedFolderURL);
    } else {
        self.folderField.stringValue = @"No folder selected";
        self.videoURLs = @[];
    }

    [self.tableView reloadData];

    NSInteger selectedIndex = selectStoredVideo ? FRIndexOfURLInVideos(self.selectedSingleVideoURL, self.videoURLs) : NSNotFound;
    if (selectedIndex != NSNotFound) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selectedIndex] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:selectedIndex];
    } else if (self.videoURLs.count > 0) {
        self.selectedSingleVideoURL = self.videoURLs.firstObject;
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:0];
    } else {
        self.selectedSingleVideoURL = nil;
        [self.tableView deselectAll:nil];
    }

    self.lastMarkedRow = FRIndexOfURLInVideos(self.selectedSingleVideoURL, self.videoURLs);
    [self reloadVideoRowsForPreviousRow:NSNotFound currentRow:self.lastMarkedRow];

    if (!self.selectedFolderURL) {
        self.statusField.stringValue = @"Choose a folder containing .mp4, .mov, or .m4v files.";
    } else if (self.videoURLs.count == 0) {
        self.statusField.stringValue = @"No supported videos found in this folder.";
    } else {
        self.statusField.stringValue = [NSString stringWithFormat:@"%lu video%@ found.",
                                        (unsigned long)self.videoURLs.count,
                                        self.videoURLs.count == 1 ? @"" : @"s"];
    }

    [self updatePreviewForCurrentSelection];
}

- (void)save:(id)sender
{
    FRPlaybackMode mode = (FRPlaybackMode)self.modePopup.selectedItem.tag;

    if (mode == FRPlaybackModeSingle && !self.selectedSingleVideoURL) {
        self.statusField.stringValue = @"Select one video for Single Video Loop.";
        return;
    }

    ScreenSaverDefaults *defaults = FRDefaults();
    [defaults setObject:FRStringForPlaybackMode(mode) forKey:FRPlaybackModeKey];
    [defaults synchronize];
    FRStoreURL(self.selectedFolderURL, FRFolderBookmarkKey, FRFolderPathKey);
    FRStoreURL(self.selectedSingleVideoURL, FRSingleVideoBookmarkKey, FRSingleVideoPathKey);

    [[NSNotificationCenter defaultCenter] postNotificationName:FRSettingsDidChangeNotification object:nil];
    [self stopPreview];
    [NSApp endSheet:self.window];
    [self.window orderOut:nil];
}

- (void)cancel:(id)sender
{
    [self stopPreview];
    [NSApp endSheet:self.window];
    [self.window orderOut:nil];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)self.videoURLs.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSTableCellView *cellView = [tableView makeViewWithIdentifier:@"VideoCell" owner:self];
    if (!cellView) {
        cellView = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cellView.identifier = @"VideoCell";

        NSTextField *field = [NSTextField labelWithString:@""];
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        field.usesSingleLineMode = YES;
        [cellView addSubview:field];
        cellView.textField = field;

        [NSLayoutConstraint activateConstraints:@[
            [field.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:8.0],
            [field.trailingAnchor constraintLessThanOrEqualToAnchor:cellView.trailingAnchor constant:-8.0],
            [field.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor constant:0.5],
        ]];
    }

    NSURL *url = self.videoURLs[(NSUInteger)row];
    NSString *title = url.lastPathComponent ?: url.path;
    NSTextField *field = cellView.textField;
    field.stringValue = FRURLsMatch(url, self.selectedSingleVideoURL) ? [NSString stringWithFormat:@"⭐️ %@", title] : title;
    field.toolTip = url.path;
    return cellView;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger previousMarkedRow = self.lastMarkedRow;
    NSInteger selectedRow = self.tableView.selectedRow;
    if (selectedRow >= 0 && selectedRow < (NSInteger)self.videoURLs.count) {
        self.selectedSingleVideoURL = self.videoURLs[(NSUInteger)selectedRow];
        self.lastMarkedRow = selectedRow;
    } else {
        if (self.videoURLs.count == 0) {
            self.selectedSingleVideoURL = nil;
            self.lastMarkedRow = NSNotFound;
        } else {
            NSInteger fallbackRow = FRIndexOfURLInVideos(self.selectedSingleVideoURL, self.videoURLs);
            if (fallbackRow == NSNotFound) {
                fallbackRow = 0;
                self.selectedSingleVideoURL = self.videoURLs.firstObject;
            }
            self.lastMarkedRow = fallbackRow;
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)fallbackRow] byExtendingSelection:NO];
        }
    }

    [self reloadVideoRowsForPreviousRow:previousMarkedRow currentRow:self.lastMarkedRow];
    [self updatePreviewForCurrentSelection];
}

- (void)reloadVideoRowsForPreviousRow:(NSInteger)previousRow currentRow:(NSInteger)currentRow
{
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    NSInteger rowCount = (NSInteger)self.videoURLs.count;
    if (previousRow != NSNotFound && previousRow >= 0 && previousRow < rowCount) {
        [rows addIndex:(NSUInteger)previousRow];
    }
    if (currentRow != NSNotFound && currentRow >= 0 && currentRow < rowCount) {
        [rows addIndex:(NSUInteger)currentRow];
    }
    if (rows.count == 0) {
        return;
    }

    NSInteger videoColumn = [self.tableView columnWithIdentifier:@"video"];
    if (videoColumn == -1) {
        return;
    }

    [self.tableView reloadDataForRowIndexes:rows
                              columnIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)videoColumn]];
}

- (void)updatePreviewForCurrentSelection
{
    NSInteger selectedRow = self.tableView.selectedRow;
    if (selectedRow < 0 || selectedRow >= (NSInteger)self.videoURLs.count) {
        [self stopPreview];
        if (self.videoURLs.count == 0) {
            [self.previewView showMessage:@"No video available."];
        } else {
            [self.previewView showMessage:@"Select a video to preview."];
        }
        return;
    }

    [self startPreviewForURL:self.videoURLs[(NSUInteger)selectedRow]];
}

- (void)startPreviewForURL:(NSURL *)url
{
    [self stopPreview];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.previewObservedItem = item;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(previewItemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    self.previewPlayer = [AVPlayer playerWithPlayerItem:item];
    self.previewPlayer.muted = YES;
    self.previewPlayer.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    [self.previewView setPreviewPlayer:self.previewPlayer];
    [self.previewPlayer play];
}

- (void)previewItemDidEnd:(NSNotification *)notification
{
    [self.previewPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
        if (finished) {
            [self.previewPlayer play];
        }
    }];
}

- (void)stopPreview
{
    if (self.previewObservedItem) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:self.previewObservedItem];
        self.previewObservedItem = nil;
    }

    [self.previewPlayer pause];
    [self.previewPlayer replaceCurrentItemWithPlayerItem:nil];
    self.previewPlayer = nil;
    [self.previewView setPreviewPlayer:nil];
}

@end

@interface FolderReelView ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) CATextLayer *messageLayer;
@property (nonatomic, strong) AVPlayerItem *observedItem;
@property (nonatomic, copy) NSArray<NSURL *> *videoURLs;
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingRandomURLs;
@property (nonatomic, strong) NSURL *lastRandomURL;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) FRPlaybackMode playbackMode;
@property (nonatomic, strong) FRConfigurationController *configurationController;
@end

@implementation FolderReelView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1/30.0];
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;

        self.playerLayer = [AVPlayerLayer layer];
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.playerLayer.hidden = YES;
        [self.layer addSublayer:self.playerLayer];

        self.messageLayer = [CATextLayer layer];
        self.messageLayer.alignmentMode = kCAAlignmentCenter;
        self.messageLayer.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        self.messageLayer.foregroundColor = [NSColor colorWithWhite:0.86 alpha:1.0].CGColor;
        self.messageLayer.wrapped = YES;
        self.messageLayer.hidden = YES;
        [self.layer addSublayer:self.messageLayer];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(settingsDidChange:)
                                                     name:FRSettingsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc
{
    [self stopObservingCurrentItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)layout
{
    [super layout];

    self.playerLayer.frame = self.bounds;
    CGFloat horizontalInset = self.isPreview ? 12.0 : 40.0;
    CGFloat width = MAX(0.0, NSWidth(self.bounds) - horizontalInset * 2.0);
    CGFloat maxWidth = self.isPreview ? width : MIN(620.0, width);
    CGFloat height = self.isPreview ? 60.0 : 110.0;
    CGFloat x = NSMidX(self.bounds) - maxWidth / 2.0;
    CGFloat y = NSMidY(self.bounds) - height / 2.0;
    self.messageLayer.frame = CGRectIntegral(CGRectMake(x, y, maxWidth, height));
    self.messageLayer.fontSize = self.isPreview ? 12.0 : 18.0;
}

- (void)startAnimation
{
    [super startAnimation];
    [self reloadPlaybackFromSettings];
    [self.player play];
}

- (void)stopAnimation
{
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.playerLayer.player = nil;
    self.player = nil;
    [self stopObservingCurrentItem];
    [super stopAnimation];
}

- (void)drawRect:(NSRect)rect
{
    [[NSColor blackColor] setFill];
    NSRectFill(rect);
}

- (void)animateOneFrame
{
    return;
}

- (BOOL)hasConfigureSheet
{
    return YES;
}

- (NSWindow*)configureSheet
{
    self.configurationController = [[FRConfigurationController alloc] init];
    return self.configurationController.window;
}

- (void)settingsDidChange:(NSNotification *)notification
{
    if (self.isAnimating) {
        [self reloadPlaybackFromSettings];
    }
}

- (void)reloadPlaybackFromSettings
{
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    [self stopObservingCurrentItem];
    self.pendingRandomURLs = nil;
    self.lastRandomURL = nil;

    ScreenSaverDefaults *defaults = FRDefaults();
    self.playbackMode = FRPlaybackModeFromString([defaults stringForKey:FRPlaybackModeKey]);

    NSURL *folderURL = FRStoredURL(FRFolderBookmarkKey, FRFolderPathKey);
    if (!folderURL) {
        [self showMessage:@"Choose a video folder in Screen Saver Options."];
        return;
    }

    self.videoURLs = FRVideoURLsInFolder(folderURL);
    if (self.videoURLs.count == 0) {
        [self showMessage:@"No .mp4, .mov, or .m4v videos found in the selected folder."];
        return;
    }

    switch (self.playbackMode) {
        case FRPlaybackModeSingle: {
            NSURL *singleURL = FRStoredURL(FRSingleVideoBookmarkKey, FRSingleVideoPathKey);
            NSInteger index = FRIndexOfURLInVideos(singleURL, self.videoURLs);
            if (index == NSNotFound) {
                [self showMessage:@"Select a video for Single Video Loop in Screen Saver Options."];
                return;
            }
            self.currentIndex = index;
            [self playURL:self.videoURLs[(NSUInteger)index]];
            break;
        }
        case FRPlaybackModeRandom:
            [self playNextRandomURL];
            break;
        case FRPlaybackModeSequence:
        default:
            self.currentIndex = 0;
            [self playURL:self.videoURLs.firstObject];
            break;
    }
}

- (void)playURL:(NSURL *)url
{
    if (!url) {
        [self showMessage:@"No playable video selected."];
        return;
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [self stopObservingCurrentItem];
    self.observedItem = item;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemFailedToPlayToEnd:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:item];

    if (!self.player) {
        self.player = [AVPlayer playerWithPlayerItem:item];
        self.player.muted = YES;
        self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        self.playerLayer.player = self.player;
    } else {
        [self.player replaceCurrentItemWithPlayerItem:item];
        self.player.muted = YES;
    }

    self.messageLayer.hidden = YES;
    self.playerLayer.hidden = NO;

    if (self.isAnimating) {
        [self.player play];
    }
}

- (void)playerItemDidEnd:(NSNotification *)notification
{
    switch (self.playbackMode) {
        case FRPlaybackModeSingle: {
            [self.player seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
                if (finished && self.isAnimating) {
                    [self.player play];
                }
            }];
            break;
        }
        case FRPlaybackModeRandom:
            [self playNextRandomURL];
            break;
        case FRPlaybackModeSequence:
        default:
            self.currentIndex = (self.currentIndex + 1) % (NSInteger)self.videoURLs.count;
            [self playURL:self.videoURLs[(NSUInteger)self.currentIndex]];
            break;
    }
}

- (void)playerItemFailedToPlayToEnd:(NSNotification *)notification
{
    if (self.videoURLs.count <= 1) {
        [self showMessage:@"This video could not be played."];
        return;
    }

    [self playerItemDidEnd:notification];
}

- (void)playNextRandomURL
{
    if (self.videoURLs.count == 0) {
        [self showMessage:@"No playable videos found."];
        return;
    }

    if (self.pendingRandomURLs.count == 0) {
        self.pendingRandomURLs = self.videoURLs.mutableCopy;
        FRShuffleMutableArray(self.pendingRandomURLs);
        if (self.lastRandomURL && self.pendingRandomURLs.count > 1 && FRURLsMatch(self.lastRandomURL, self.pendingRandomURLs.firstObject)) {
            [self.pendingRandomURLs exchangeObjectAtIndex:0 withObjectAtIndex:1];
        }
    }

    NSURL *nextURL = self.pendingRandomURLs.firstObject;
    [self.pendingRandomURLs removeObjectAtIndex:0];
    self.lastRandomURL = nextURL;
    [self playURL:nextURL];
}

- (void)showMessage:(NSString *)message
{
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    [self stopObservingCurrentItem];
    self.playerLayer.hidden = YES;
    self.messageLayer.string = message ?: @"";
    self.messageLayer.hidden = message.length == 0;
    [self setNeedsDisplay:YES];
}

- (void)stopObservingCurrentItem
{
    if (!self.observedItem) {
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:self.observedItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:self.observedItem];
    self.observedItem = nil;
}

@end
