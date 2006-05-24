//
//  ArticleListView.m
//  Vienna
//
//  Created by Steve on 8/27/05.
//  Copyright (c) 2004-2005 Steve Palmer. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "ArticleListView.h"
#import "Preferences.h"
#import "Constants.h"
#import "AppController.h"
#import "ArticleController.h"
#import "SplitViewExtensions.h"
#import "MessageListView.h"
#import "ArticleView.h"
#import "FoldersTree.h"
#import "CalendarExtensions.h"
#import "StringExtensions.h"
#import "HelperFunctions.h"
#import "ArticleRef.h"
#import "ArticleFilter.h"
#import "XMLParser.h"
#import "WebKit/WebUIDelegate.h"
#import "WebKit/WebDataSource.h"
#import "WebKit/WebBackForwardList.h"

// Private functions
@interface ArticleListView (Private)
	-(void)setArticleListHeader;
	-(void)initTableView;
	-(BOOL)copyTableSelection:(NSArray *)rows toPasteboard:(NSPasteboard *)pboard;
	-(void)setTableViewFont;
	-(void)showSortDirection;
	-(void)selectArticleAfterReload;
	-(void)handleFolderNameChange:(NSNotification *)nc;
	-(void)handleFolderUpdate:(NSNotification *)nc;
	-(void)handleReadingPaneChange:(NSNotificationCenter *)nc;
	-(void)handleRefreshArticle:(NSNotification *)nc;
	-(BOOL)scrollToArticle:(NSString *)guid;
	-(void)selectFirstUnreadInFolder;
	-(BOOL)viewNextUnreadInCurrentFolder:(int)currentRow;
	-(void)loadMinimumFontSize;
	-(void)markCurrentRead:(NSTimer *)aTimer;
	-(void)refreshImmediatelyArticleAtCurrentRow;
	-(void)refreshArticleAtCurrentRow:(BOOL)delayFlag;
	-(void)makeRowSelectedAndVisible:(int)rowIndex;
	-(void)refreshArticlePane;
	-(void)updateArticleListRowHeight;
	-(void)setOrientation:(int)newLayout;
	-(void)loadSplitSettingsForLayout;
	-(void)saveSplitSettingsForLayout;
	-(void)printDocument;
@end

static const int MA_Minimum_ArticleList_Pane_Width = 80;
static const int MA_Minimum_Article_Pane_Width = 80;

@implementation ArticleListView

/* initWithFrame
 * Initialise our view.
 */
-(id)initWithFrame:(NSRect)frame
{
    if (([super initWithFrame:frame]) != nil)
	{
		isChangingOrientation = NO;
		isInTableInit = NO;
		blockSelectionHandler = NO;
		blockMarkRead = NO;
		guidOfArticleToSelect = nil;
		markReadTimer = nil;
		selectionTimer = nil;
    }
    return self;
}

/* awakeFromNib
 * Do things that only make sense once the NIB is loaded.
 */
-(void)awakeFromNib
{
	// Register to be notified when folders are added or removed
	NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(handleArticleListFontChange:) name:@"MA_Notify_ArticleListFontChange" object:nil];
	[nc addObserver:self selector:@selector(handleReadingPaneChange:) name:@"MA_Notify_ReadingPaneChange" object:nil];
	[nc addObserver:self selector:@selector(handleFolderUpdate:) name:@"MA_Notify_FoldersUpdated" object:nil];
	[nc addObserver:self selector:@selector(handleFolderNameChange:) name:@"MA_Notify_FolderNameChanged" object:nil];
	[nc addObserver:self selector:@selector(handleFilterChange:) name:@"MA_Notify_FilteringChange" object:nil];
	[nc addObserver:self selector:@selector(handleRefreshArticle:) name:@"MA_Notify_ArticleViewChange" object:nil];

	// Make us the frame load and UI delegate for the web view
	[articleText setUIDelegate:self];
	[articleText setFrameLoadDelegate:self];
	[articleText setOpenLinksInNewBrowser:YES];
	[articleText setController:controller];

	// Set the filters popup menu
	[controller initFiltersMenu:filtersPopupMenu];

	// Disable caching
	[articleText setMaintainsBackForwardList:NO];
	[[articleText backForwardList] setPageCacheSize:0];
}

/* initialiseArticleView
 * Do the things to initialise the article view from the database. This is the
 * only point during initialisation where the database is guaranteed to be
 * ready for use.
 */
-(void)initialiseArticleView
{
	Preferences * prefs = [Preferences standardPreferences];

	// Mark the start of the init phase
	isAppInitialising = YES;
	
	// Create condensed view attribute dictionaries
	selectionDict = [[NSMutableDictionary alloc] init];
	unreadTopLineDict = [[NSMutableDictionary alloc] init];
	topLineDict = [[NSMutableDictionary alloc] init];
	unreadTopLineSelectionDict = [[NSMutableDictionary alloc] init];
	middleLineDict = [[NSMutableDictionary alloc] init];
	linkLineDict = [[NSMutableDictionary alloc] init];
	bottomLineDict = [[NSMutableDictionary alloc] init];
	
	// Set the reading pane orientation
	[self setOrientation:[prefs layout]];
	[splitView2 setDelegate:self];
	
	// Initialise the article list view
	[self initTableView];

	// Done initialising
	isAppInitialising = NO;
}

/* constrainMinCoordinate
 * Make sure the article pane width isn't shrunk beyond a minimum width. Otherwise it looks
 * untidy.
 */
-(float)splitView:(NSSplitView *)sender constrainMinCoordinate:(float)proposedMin ofSubviewAt:(int)offset
{
	return (sender == splitView2 && offset == 0) ? MA_Minimum_ArticleList_Pane_Width : proposedMin;
}

/* constrainMaxCoordinate
 * Make sure that the article pane isn't shrunk beyond a minimum size otherwise the splitview
 * or controls within it start resizing odd.
 */
-(float)splitView:(NSSplitView *)sender constrainMaxCoordinate:(float)proposedMax ofSubviewAt:(int)offset
{
	if (sender == splitView2 && offset == 0)
	{
		NSRect mainFrame = [[splitView2 superview] frame];
		return (tableLayout == MA_Layout_Condensed) ?
			mainFrame.size.width - MA_Minimum_Article_Pane_Width :
			mainFrame.size.height - MA_Minimum_Article_Pane_Width;
	}
	return proposedMax;
}

/* resizeSubviewsWithOldSize
 * Constrain the article list pane to a fixed width.
 */
-(void)splitView:(NSSplitView *)sender resizeSubviewsWithOldSize:(NSSize)oldSize
{
	float dividerThickness = [sender dividerThickness];
	id sv1 = [[sender subviews] objectAtIndex:0];
	id sv2 = [[sender subviews] objectAtIndex:1];
	NSRect leftFrame = [sv1 frame];
	NSRect rightFrame = [sv2 frame];
	NSRect newFrame = [sender frame];
	
	if (sender == splitView2)
	{
		if (isChangingOrientation)
			[splitView2 adjustSubviews];
		else
		{
			leftFrame.origin = NSMakePoint(0, 0);
			if (tableLayout == MA_Layout_Condensed)
			{
				leftFrame.size.height = newFrame.size.height;
				rightFrame.size.width = newFrame.size.width - leftFrame.size.width - dividerThickness;
				rightFrame.size.height = newFrame.size.height;
				rightFrame.origin.x = leftFrame.size.width + dividerThickness;
			}
			else
			{
				leftFrame.size.width = newFrame.size.width;
				rightFrame.size.height = newFrame.size.height - leftFrame.size.height - dividerThickness;
				rightFrame.size.width = newFrame.size.width;
				rightFrame.origin.y = leftFrame.size.height + dividerThickness;
			}
			[sv1 setFrame:leftFrame];
			[sv2 setFrame:rightFrame];
		}
	}
}

/* createWebViewWithRequest
 * Called when the browser wants to create a new window. The request is opened in a new tab.
 */
-(WebView *)webView:(WebView *)sender createWebViewWithRequest:(NSURLRequest *)request
{
	[controller openURL:[request URL] inPreferredBrowser:YES];
	// Change this to handle modifier key?
	// Is this covered by the webView policy?
	return nil;
}

/* setStatusText
 * Called from the webview when some JavaScript writes status text. Echo this to
 * our status bar.
 */
-(void)webView:(WebView *)sender setStatusText:(NSString *)text
{
	[controller setStatusMessage:text persist:NO];
}

/* mouseDidMoveOverElement
 * Called from the webview when the user positions the mouse over an element. If it's a link
 * then echo the URL to the status bar like Safari does.
 */
-(void)webView:(WebView *)sender mouseDidMoveOverElement:(NSDictionary *)elementInformation modifierFlags:(unsigned int)modifierFlags
{
	NSURL * url = [elementInformation valueForKey:@"WebElementLinkURL"];
	[controller setStatusMessage:(url ? [url absoluteString] : @"") persist:NO];
}

/* contextMenuItemsForElement
 * Creates a new context menu for our web view.
 */
-(NSArray *)webView:(WebView *)sender contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:(NSArray *)defaultMenuItems
{
	NSURL * urlLink = [element valueForKey:WebElementLinkURLKey];
	return (urlLink != nil) ? [controller contextMenuItemsForElement:(NSDictionary *)element defaultMenuItems:defaultMenuItems] : nil;
}

/* initTableView
 * Do all the initialization for the article list table view control
 */
-(void)initTableView
{
	Preferences * prefs = [Preferences standardPreferences];
	
	// Variable initialization here
	currentSelectedRow = -1;
	articleListFont = nil;
	articleListUnreadFont = nil;

	// Initialize the article columns from saved data
	NSArray * dataArray = [prefs arrayForKey:MAPref_ArticleListColumns];
	Database * db = [Database sharedDatabase];
	Field * field;
	unsigned int index;
	
	for (index = 0; index < [dataArray count];)
	{
		NSString * name;
		int width = 100;
		BOOL visible = NO;
		
		name = [dataArray objectAtIndex:index++];
		if (index < [dataArray count])
			visible = [[dataArray objectAtIndex:index++] intValue] == YES;
		if (index < [dataArray count])
			width = [[dataArray objectAtIndex:index++] intValue];
		
		field = [db fieldByName:name];
		[field setVisible:visible];
		[field setWidth:width];
	}
	
	// In condensed mode, the summary field takes up the whole space
	if ([articleList respondsToSelector:@selector(setColumnAutoresizingStyle:)])
		[articleList setColumnAutoresizingStyle:NSTableViewSequentialColumnAutoresizingStyle];
	else
		[articleList setAutoresizesAllColumnsToFit:NO];
	
	// Get the default list of visible columns
	[self updateVisibleColumns];
	
	// Dynamically create the popup menu. This is one less thing to
	// explicitly localise in the NIB file.
	NSMenu * articleListMenu = [[NSMenu alloc] init];
	[articleListMenu addItem:copyOfMenuWithAction(@selector(markRead:))];
	[articleListMenu addItem:copyOfMenuWithAction(@selector(markFlagged:))];
	[articleListMenu addItem:copyOfMenuWithAction(@selector(deleteMessage:))];
	[articleListMenu addItem:copyOfMenuWithAction(@selector(restoreMessage:))];
	[articleListMenu addItem:[NSMenuItem separatorItem]];
	[articleListMenu addItem:copyOfMenuWithAction(@selector(viewSourceHomePage:))];
	NSMenuItem * alternateItem = copyOfMenuWithAction(@selector(viewSourceHomePageInAlternateBrowser:));
	[alternateItem setKeyEquivalentModifierMask:NSAlternateKeyMask];
	[alternateItem setAlternate:YES];
	[articleListMenu addItem:alternateItem];
	[articleListMenu addItem:copyOfMenuWithAction(@selector(viewArticlePage:))];
	alternateItem = copyOfMenuWithAction(@selector(viewArticlePageInAlternateBrowser:));
	[alternateItem setKeyEquivalentModifierMask:NSAlternateKeyMask];
	[alternateItem setAlternate:YES];
	[articleListMenu addItem:alternateItem];
	[articleList setMenu:articleListMenu];
	[articleListMenu release];

	// Set the target for double-click actions
	[articleList setDoubleAction:@selector(doubleClickRow:)];
	[articleList setAction:@selector(singleClickRow:)];
	[articleList setDelegate:self];
	[articleList setDataSource:self];
	[articleList setTarget:self];

	// Set the default fonts
	[self setTableViewFont];
}

/* singleClickRow
 * Handle a single click action. If the click was in the read or flagged column then
 * treat it as an action to mark the article read/unread or flagged/unflagged. Later
 * trap the comments column and expand/collapse.
 */
-(IBAction)singleClickRow:(id)sender
{
	int row = [articleList clickedRow];
	int column = [articleList clickedColumn];
	NSArray * allArticles = [articleController allArticles];
	
	if (row >= 0 && row < (int)[allArticles count])
	{
		NSArray * columns = [articleList tableColumns];
		if (column >= 0 && column < (int)[columns count])
		{
			Article * theArticle = [allArticles objectAtIndex:row];
			NSString * columnName = [(NSTableColumn *)[columns objectAtIndex:column] identifier];
			if ([columnName isEqualToString:MA_Field_Read])
			{
				[articleController markReadByArray:[NSArray arrayWithObject:theArticle] readFlag:![theArticle isRead]];
				return;
			}
			if ([columnName isEqualToString:MA_Field_Flagged])
			{
				[articleController markFlaggedByArray:[NSArray arrayWithObject:theArticle] flagged:![theArticle isFlagged]];
				return;
			}
		}
	}
}

/* doubleClickRow
 * Handle double-click on the selected article. Open the original feed item in
 * the default browser.
 */
-(IBAction)doubleClickRow:(id)sender
{
	if (currentSelectedRow != -1 && [articleList clickedRow] != -1)
	{
		Article * theArticle = [[articleController allArticles] objectAtIndex:currentSelectedRow];
		[controller openURLFromString:[theArticle link] inPreferredBrowser:YES];
	}
}

/* updateAlternateMenuTitle
 * Sets the approprate title for the alternate item in the contextual menu
 * when user changes preference for opening pages in external browser
 */
-(void)updateAlternateMenuTitle
{
	NSMenuItem * mainMenuItem;
	NSMenuItem * contextualMenuItem;
	int index;
	NSMenu * articleListMenu = [articleList menu];
	if (articleListMenu == nil)
		return;
	mainMenuItem = menuWithAction(@selector(viewSourceHomePageInAlternateBrowser:));
	if (mainMenuItem != nil)
	{
		index = [articleListMenu indexOfItemWithTarget:nil andAction:@selector(viewSourceHomePageInAlternateBrowser:)];
		if (index >= 0)
		{
			contextualMenuItem = [articleListMenu itemAtIndex:index];
			[contextualMenuItem setTitle:[mainMenuItem title]];
		}
	}
	mainMenuItem = menuWithAction(@selector(viewArticlePageInAlternateBrowser:));
	if (mainMenuItem != nil)
	{
		index = [articleListMenu indexOfItemWithTarget:nil andAction:@selector(viewArticlePageInAlternateBrowser:)];
		if (index >= 0)
		{
			contextualMenuItem = [articleListMenu itemAtIndex:index];
			[contextualMenuItem setTitle:[mainMenuItem title]];
		}
	}
}

/* ensureSelectedArticle
 * Ensure that there is a selected article and that it is visible.
 */
-(void)ensureSelectedArticle:(BOOL)singleSelection
{
	if (singleSelection)
	{
		int nextRow = [[articleList selectedRowIndexes] firstIndex];
		int articlesCount = [[articleController allArticles] count];

		currentSelectedRow = -1;
		if (nextRow < 0 || nextRow >= articlesCount)
			nextRow = articlesCount - 1;
		[self makeRowSelectedAndVisible:nextRow];
	}
	else
	{
		if ([articleList selectedRow] == -1)
			[self makeRowSelectedAndVisible:0];
		else
			[articleList scrollRowToVisible:[articleList selectedRow]];
	}
}

/* updateVisibleColumns
 * Iterates through the array of visible columns and makes them
 * visible or invisible as needed.
 */
-(void)updateVisibleColumns
{
	NSArray * fields = [[Database sharedDatabase] arrayOfFields];
	int count = [fields count];
	int index;

	// Save current selection
	NSIndexSet * selArray = [articleList selectedRowIndexes];
	
	// Mark we're doing an update of the tableview
	isInTableInit = YES;
	
	// Remove old columns
	NSEnumerator * enumerator = [[articleList tableColumns] objectEnumerator];
	id nextObject;
	while ((nextObject = [enumerator nextObject]))
		[articleList removeTableColumn:nextObject];
	
	[self updateArticleListRowHeight];
	
	// Create the new columns
	for (index = 0; index < count; ++index)
	{
		Field * field = [fields objectAtIndex:index];
		NSString * identifier = [field name];
		int tag = [field tag];
		BOOL showField;
		
		// Handle condensed layout vs. table layout
		if (tableLayout == MA_Layout_Report)
			showField = [field visible] && tag != MA_FieldID_Headlines && tag != MA_FieldID_Comments;
		else
		{
			showField = NO;
			if (tag == MA_FieldID_Read || tag == MA_FieldID_Flagged)
				showField = [field visible];
			if (tag == MA_FieldID_Headlines)
				showField = YES;
		}

		// Add to the end only those columns that are visible
		if (showField)
		{
			NSTableColumn * column = [[NSTableColumn alloc] initWithIdentifier:identifier];
			
			// Fix for bug where tableviews with alternating background rows lose their "colour".
			// Only text cells are affected.
			if ([[column dataCell] isKindOfClass:[NSTextFieldCell class]])
			{
				[[column dataCell] setDrawsBackground:NO];
				[[column dataCell] setWraps:YES];
			}

			NSTableHeaderCell * headerCell = [column headerCell];
			BOOL isResizable = (tag != MA_FieldID_Read && tag != MA_FieldID_Flagged && tag != MA_FieldID_Comments);

			[headerCell setTitle:[field displayName]];
			[column setEditable:NO];
			if([column respondsToSelector: @selector(setResizingMask:)]) {
				[column setResizingMask:isResizable ? (NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask) : NSTableColumnNoResizing];
			}
			else {
				[column setResizable:isResizable];
			}
			[column setMinWidth:10];
			[column setMaxWidth:1000];
			[column setWidth:[field width]];
			[articleList addTableColumn:column];
			[column release];
		}
	}
	
	// Set the extended date formatter on the Date column
	NSTableColumn * tableColumn = [articleList tableColumnWithIdentifier:MA_Field_Date];
	if (tableColumn != nil)
	{
		if (extDateFormatter == nil)
			extDateFormatter = [[ExtDateFormatter alloc] init];
		[[tableColumn dataCell] setFormatter:extDateFormatter];
	}

	// Set the images for specific header columns
	[articleList setHeaderImage:MA_Field_Read imageName:@"unread_header.tiff"];
	[articleList setHeaderImage:MA_Field_Flagged imageName:@"flagged_header.tiff"];

	// Initialise the sort direction
	[self showSortDirection];	
	
	// Put the selection back
	[articleList selectRowIndexes:selArray byExtendingSelection:NO];
	
	// Done
	isInTableInit = NO;
}

/* saveTableSettings
 * Save the table column settings, specifically the visibility and width.
 */
-(void)saveTableSettings
{
	Preferences * prefs = [Preferences standardPreferences];
	NSArray * fields = [[Database sharedDatabase] arrayOfFields];
	NSEnumerator * enumerator = [fields objectEnumerator];
	Field * field;
	
	// Remember the current folder and article
	NSString * guid = (currentSelectedRow >= 0) ? [[[articleController allArticles] objectAtIndex:currentSelectedRow] guid] : @"";
	[prefs setInteger:[articleController currentFolderId] forKey:MAPref_CachedFolderID];
	[prefs setString:guid forKey:MAPref_CachedArticleGUID];

	// An array we need for the settings
	NSMutableArray * dataArray = [[NSMutableArray alloc] init];
	
	// Create the new columns
	while ((field = [enumerator nextObject]) != nil)
	{
		[dataArray addObject:[field name]];
		[dataArray addObject:[NSNumber numberWithBool:[field visible]]];
		[dataArray addObject:[NSNumber numberWithInt:[field width]]];
	}
	
	// Save these to the preferences
	[prefs setObject:dataArray forKey:MAPref_ArticleListColumns];

	// Save the split bar position
	[self saveSplitSettingsForLayout];

	// We're done
	[dataArray release];
}

/* setTableViewFont
 * Gets the font for the article list and adjusts the table view
 * row height to properly display that font.
 */
-(void)setTableViewFont
{
	[articleListFont release];
	[articleListUnreadFont release];

	Preferences * prefs = [Preferences standardPreferences];
	articleListFont = [NSFont fontWithName:[prefs articleListFont] size:[prefs articleListFontSize]];
	articleListUnreadFont = [prefs boolForKey:MAPref_ShowUnreadArticlesInBold] ? [[NSFontManager sharedFontManager] convertWeight:YES ofFont:articleListFont] : articleListFont;

	NSMutableParagraphStyle * style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
	[style setLineBreakMode:NSLineBreakByTruncatingTail];
	
	[topLineDict setObject:articleListFont forKey:NSFontAttributeName];
	[topLineDict setObject:style forKey:NSParagraphStyleAttributeName];
	[topLineDict setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];

	[unreadTopLineDict setObject:articleListUnreadFont forKey:NSFontAttributeName];
	[unreadTopLineDict setObject:style forKey:NSParagraphStyleAttributeName];
	[unreadTopLineDict setObject:[NSColor blackColor] forKey:NSForegroundColorAttributeName];
	
	[middleLineDict setObject:articleListFont forKey:NSFontAttributeName];
	[middleLineDict setObject:style forKey:NSParagraphStyleAttributeName];
	[middleLineDict setObject:[NSColor blueColor] forKey:NSForegroundColorAttributeName];
	
	[linkLineDict setObject:articleListFont forKey:NSFontAttributeName];
	[linkLineDict setObject:style forKey:NSParagraphStyleAttributeName];
	[linkLineDict setObject:self forKey:NSLinkAttributeName];
	[linkLineDict setObject:[NSColor blueColor] forKey:NSForegroundColorAttributeName];

	[bottomLineDict setObject:articleListFont forKey:NSFontAttributeName];
	[bottomLineDict setObject:style forKey:NSParagraphStyleAttributeName];
	[bottomLineDict setObject:[NSColor grayColor] forKey:NSForegroundColorAttributeName];

	[selectionDict setObject:articleListFont forKey:NSFontAttributeName];
	[selectionDict setObject:style forKey:NSParagraphStyleAttributeName];
	[selectionDict setObject:[NSColor whiteColor] forKey:NSForegroundColorAttributeName];

	[unreadTopLineSelectionDict setObject:articleListUnreadFont forKey:NSFontAttributeName];
	[unreadTopLineSelectionDict setObject:style forKey:NSParagraphStyleAttributeName];
	[unreadTopLineSelectionDict setObject:[NSColor whiteColor] forKey:NSForegroundColorAttributeName];
	
	[self updateArticleListRowHeight];
	[style release];
}

/* updateArticleListRowHeight
 * Compute the number of rows that the current view requires. For table layout, there's just
 * one line. For condensed layout, the number of lines depends on which fields are visible but
 * there's always a minimum of one line anyway.
 */
-(void)updateArticleListRowHeight
{
	Database * db = [Database sharedDatabase];
	int height = [articleListFont defaultLineHeightForFont];
	int numberOfRowsInCell;

	if (tableLayout == MA_Layout_Report)
		numberOfRowsInCell = 1;
	else
	{
		numberOfRowsInCell = 0;
		if ([[db fieldByName:MA_Field_Subject] visible])
			++numberOfRowsInCell;
		if ([[db fieldByName:MA_Field_Folder] visible] || [[db fieldByName:MA_Field_Date] visible] || [[db fieldByName:MA_Field_Author] visible])
			++numberOfRowsInCell;
		if ([[db fieldByName:MA_Field_Link] visible])
			++numberOfRowsInCell;
		if ([[db fieldByName:MA_Field_Summary] visible])
			++numberOfRowsInCell;
		if (numberOfRowsInCell == 0)
			++numberOfRowsInCell;
	}
	[articleList setRowHeight:(height + 2) * numberOfRowsInCell];
}

/* showSortDirection
 * Shows the current sort column and direction in the table.
 */
-(void)showSortDirection
{
	NSTableColumn * sortColumn = [articleList tableColumnWithIdentifier:[articleController sortColumnIdentifier]];
	NSString * imageName = ([[[[Preferences standardPreferences] articleSortDescriptors] objectAtIndex:0] ascending]) ? @"NSAscendingSortIndicator" : @"NSDescendingSortIndicator";
	[articleList setHighlightedTableColumn:sortColumn];
	[articleList setIndicatorImage:[NSImage imageNamed:imageName] inTableColumn:sortColumn];
}

/* scrollToArticle
 * Moves the selection to the specified article. Returns YES if we found the
 * article, NO otherwise.
 */
-(BOOL)scrollToArticle:(NSString *)guid
{
	NSEnumerator * enumerator = [[articleController allArticles] objectEnumerator];
	Article * thisArticle;
	int rowIndex = 0;
	BOOL found = NO;
	
	while ((thisArticle = [enumerator nextObject]) != nil)
	{
		if ([[thisArticle guid] isEqualToString:guid])
		{
			[self makeRowSelectedAndVisible:rowIndex];
			found = YES;
			break;
		}
		++rowIndex;
	}
	return found;
}

/* mainView
 * Return the primary view of this view.
 */
-(NSView *)mainView
{
	return articleList;
}

/* webView
 * Returns the webview used to display the articles
 */
-(WebView *)webView
{
	return articleText;
}

/* canGoForward
 * Return TRUE if we can go forward in the backtrack queue.
 */
-(BOOL)canGoForward
{
	return [articleController canGoForward];
}

/* canGoBack
 * Return TRUE if we can go backward in the backtrack queue.
 */
-(BOOL)canGoBack
{
	return [articleController canGoBack];
}

/* handleGoForward
 * Move forward through the backtrack queue.
 */
-(IBAction)handleGoForward:(id)sender
{
	[articleController goForward];
}

/* handleGoBack
 * Move backward through the backtrack queue.
 */
-(IBAction)handleGoBack:(id)sender
{
	[articleController goBack];
}

/* handleKeyDown [delegate]
 * Support special key codes. If we handle the key, return YES otherwise
 * return NO to allow the framework to pass it on for default processing.
 */
-(BOOL)handleKeyDown:(unichar)keyChar withFlags:(unsigned int)flags
{
	return [controller handleKeyDown:keyChar withFlags:flags];
}

/* selectedArticle
 * Returns the selected article, or nil if no article is selected.
 */
-(Article *)selectedArticle
{
	return (currentSelectedRow >= 0) ? [[articleController allArticles] objectAtIndex:currentSelectedRow] : nil;
}

/* printDocument
 * Print the active article.
 */
-(void)printDocument:(id)sender
{
	[articleText printDocument:sender];
}

/* handleFilterChange
 * Update the list of articles when the user changes the filter.
 */
-(void)handleFilterChange:(NSNotification *)nc
{
	[articleController refilterArrayOfArticles];
	[self refreshFolder:MA_Refresh_RedrawList];
	if (([self selectedArticle] == nil) && ([[NSApp mainWindow] firstResponder] == articleList))
		[[NSApp mainWindow] makeFirstResponder:[foldersTree mainView]];
}

/* handleFolderNameChange
 * Some folder metadata changed. Update the article list header and the
 * current article with a possible name change.
 */
-(void)handleFolderNameChange:(NSNotification *)nc
{
	int folderId = [(NSNumber *)[nc object] intValue];
	if (folderId == [articleController currentFolderId])
	{
		[self setArticleListHeader];
		[self refreshArticlePane];
	}
}

/* handleFolderUpdate
 * Called if a folder content has changed.
 */
-(void)handleFolderUpdate:(NSNotification *)nc
{
	int folderId = [(NSNumber *)[nc object] intValue];
	if (folderId == 0 || folderId == [articleController currentFolderId] || [articleController currentCacheContainsFolder:folderId])
		[self refreshFolder:MA_Refresh_ReloadFromDatabase];
	else
	{
		Folder * folder = [[Database sharedDatabase] folderFromID:[articleController currentFolderId]];
		if (IsSmartFolder(folder) && ![controller isConnecting])
			[self refreshFolder:MA_Refresh_ReloadFromDatabase];
	}
}

/* handleArticleListFontChange
 * Called when the user changes the article list font and/or size in the Preferences
 */
-(void)handleArticleListFontChange:(NSNotification *)note
{
	[self setTableViewFont];
	[articleList reloadData];
}

/* handleReadingPaneChange
 * Respond to the change to the reading pane orientation.
 */
-(void)handleReadingPaneChange:(NSNotificationCenter *)nc
{
	[self saveSplitSettingsForLayout];
	[self setOrientation:[[Preferences standardPreferences] layout]];
	[self updateVisibleColumns];
	[articleList reloadData];
}

/* loadSplitSettingsForLayout
 * Set the splitview position for the current layout from the preferences.
 */
-(void)loadSplitSettingsForLayout
{
	NSString * splitPrefsName = (tableLayout == MA_Layout_Report) ? @"SplitView2ReportLayout" : @"SplitView2CondensedLayout";
	[splitView2 setLayout:[[Preferences standardPreferences] objectForKey:splitPrefsName]];
}

/* saveSplitSettingsForLayout
 * Save the splitview position for the current layout to the preferences.
 */
-(void)saveSplitSettingsForLayout
{
	NSString * splitPrefsName = (tableLayout == MA_Layout_Report) ? @"SplitView2ReportLayout" : @"SplitView2CondensedLayout";
	[[Preferences standardPreferences] setObject:[splitView2 layout] forKey:splitPrefsName];
}

/* setOrientation
 * Adjusts the article view orientation and updates the article list row
 * height to accommodate the summary view
 */
-(void)setOrientation:(int)newLayout
{
	isChangingOrientation = YES;
	tableLayout = newLayout;
	[splitView2 setVertical:(newLayout == MA_Layout_Condensed)];
	[self loadSplitSettingsForLayout];
	[splitView2 display];
	isChangingOrientation = NO;
}

/* tableLayout
 * Returns the active table layout.
 */
-(int)tableLayout
{
	return tableLayout;
}

/* makeRowSelectedAndVisible
 * Selects the specified row in the table and makes it visible by
 * scrolling it to the center of the table.
 */
-(void)makeRowSelectedAndVisible:(int)rowIndex
{
	if ([[articleController allArticles] count] == 0u)
		currentSelectedRow = -1;
	else if (rowIndex == currentSelectedRow)
		[self refreshArticleAtCurrentRow:NO];
	else
	{
		[articleList selectRow:rowIndex byExtendingSelection:NO]; // Warning: this method has been deprecated.  Should be changed to selectRowIndexes:byExtendingSelection:
		if (currentSelectedRow == -1 || blockSelectionHandler)
		{
			currentSelectedRow = rowIndex;
			[self refreshImmediatelyArticleAtCurrentRow];
		}

		int pageSize = [articleList rowsInRect:[articleList visibleRect]].length;
		int lastRow = [articleList numberOfRows] - 1;
		int visibleRow = currentSelectedRow + (pageSize / 2);

		if (visibleRow > lastRow)
			visibleRow = lastRow;
		[articleList scrollRowToVisible:currentSelectedRow];
		[articleList scrollRowToVisible:visibleRow];
	}
}

/* displayNextUnread
 * Locate the next unread article from the current article onward.
 */
-(void)displayNextUnread
{
	// Mark the current article read
	[self markCurrentRead:nil];

	// Scan the current folder from the selection forward. If nothing found, try
	// other folders until we come back to ourselves.
	if (![self viewNextUnreadInCurrentFolder:currentSelectedRow])
	{
		int nextFolderWithUnread = [foldersTree nextFolderWithUnread:[articleController currentFolderId]];
		if (nextFolderWithUnread != -1)
		{
			if (nextFolderWithUnread == [articleController currentFolderId])
				[self viewNextUnreadInCurrentFolder:-1];
			else
			{
				guidOfArticleToSelect = nil;
				[foldersTree selectFolder:nextFolderWithUnread];
				[self selectFirstUnreadInFolder];
			}
		}
	}
}

/* viewNextUnreadInCurrentFolder
 * Select the next unread article in the current folder after currentRow.
 */
-(BOOL)viewNextUnreadInCurrentFolder:(int)currentRow
{
	NSArray * allArticles = [articleController allArticles];
	int totalRows = [allArticles count];
	if (currentRow < totalRows - 1)
	{
		Article * theArticle;
		
		do {
			theArticle = [allArticles objectAtIndex:++currentRow];
			if (![theArticle isRead])
			{
				[self makeRowSelectedAndVisible:currentRow];
				return YES;
			}
		} while (currentRow < totalRows - 1);
	}
	return NO;
}

/* selectFirstUnreadInFolder
 * Moves the selection to the first unread article in the current article list or the
 * last article if the folder has no unread articles.
 */
-(void)selectFirstUnreadInFolder
{
	if (![self viewNextUnreadInCurrentFolder:-1])
	{
		int count = [[articleController allArticles] count];
		if (count > 0)
			[self makeRowSelectedAndVisible:[[[[Preferences standardPreferences] articleSortDescriptors] objectAtIndex:0] ascending] ? 0 : count - 1];
	}
}

/* selectFolderAndArticle
 * Select a folder and select a specified article within the folder.
 */
-(void)selectFolderAndArticle:(int)folderId guid:(NSString *)guid
{
	// If we're in the right folder, easy enough.
	if (folderId == [articleController currentFolderId])
		[self scrollToArticle:guid];
	else
	{
		// Otherwise we force the folder to be selected and seed guidOfArticleToSelect
		// so that after handleFolderSelection has been invoked, it will select the
		// requisite article on our behalf.
		currentSelectedRow = -1;
		[guidOfArticleToSelect release];
		guidOfArticleToSelect = [guid retain];
		[foldersTree selectFolder:folderId];
	}
}

/* viewLink
 * There's no view link address for article views. If we eventually implement a local
 * scheme such as vienna:<feedurl>/<guid> then we could use that as a link address.
 */
-(NSString *)viewLink
{
	return nil;
}

/* performFindPanelAction
 * Implement the search action.
 */
-(void)performFindPanelAction:(int)actionTag
{
	[self refreshFolder:MA_Refresh_ReloadFromDatabase];
	if (currentSelectedRow < 0 && [[articleController allArticles] count] > 0)
		[self makeRowSelectedAndVisible:0];
}

/* refreshFolder
 * Refreshes the current folder by applying the current sort or thread
 * logic and redrawing the article list. The selected article is preserved
 * and restored on completion of the refresh.
 */
-(void)refreshFolder:(int)refreshFlag
{
	NSArray * allArticles = [articleController allArticles];
	NSString * guid = nil;

	[markReadTimer invalidate];
	[markReadTimer release];
	markReadTimer = nil;
	
	if (refreshFlag == MA_Refresh_SortAndRedraw)
		blockSelectionHandler = blockMarkRead = YES;		
	if (currentSelectedRow >= 0 && currentSelectedRow < [allArticles count])
		guid = [[[allArticles objectAtIndex:currentSelectedRow] guid] retain];
	if (refreshFlag == MA_Refresh_ReloadFromDatabase)
		[articleController reloadArrayOfArticles];
	[self setArticleListHeader];
	[articleController sortArticles];
	[self showSortDirection];
	[articleList reloadData];
	if (guid != nil)
	{
		// To avoid upsetting the current displayed article after a refresh, we check to see if the selection has stayed
		// the same and the GUID of the article at the selection is the same. If so, don't refresh anything.
		NSArray * allArticles = [articleController allArticles];
		BOOL isUnchanged = currentSelectedRow >= 0 &&
						   currentSelectedRow < [allArticles count] &&
						   [guid isEqualToString:[[allArticles objectAtIndex:currentSelectedRow] guid]];
		if (!isUnchanged)
		{
			if (![self scrollToArticle:guid])
				currentSelectedRow = -1;
			else
				[self refreshArticlePane];
		}
	}
	if (refreshFlag == MA_Refresh_SortAndRedraw)
		blockSelectionHandler = blockMarkRead = NO;		
	[guid release];
}

/* setArticleListHeader
 * Set the article list header caption to the name of the current folder.
 */
-(void)setArticleListHeader
{
	Folder * folder = [[Database sharedDatabase] folderFromID:[articleController currentFolderId]];
	ArticleFilter * filter = [ArticleFilter filterByTag:[[Preferences standardPreferences] filterMode]];
	NSString * captionString = [NSString stringWithFormat: NSLocalizedString(@"%@ (Filtered: %@)", nil), [folder name], NSLocalizedString([filter name], nil)];
	[articleListHeader setStringValue:captionString];
}

/* selectArticleAfterReload
 * Sets the selection in the article list after the list is reloaded. The value of guidOfArticleToSelect
 * is either MA_Select_None, meaning no selection, MA_Select_Unread meaning select the first unread
 * article from the beginning (after sorting is applied) or it is the ID of a specific article to be
 * selected.
 */
-(void)selectArticleAfterReload
{
	if (guidOfArticleToSelect == nil)
		[self selectFirstUnreadInFolder];
	else
		[self scrollToArticle:guidOfArticleToSelect];
	[guidOfArticleToSelect release];
	guidOfArticleToSelect = nil;
}

/* menuWillAppear
 * Called when the popup menu is opened on the table. We ensure that the item under the
 * cursor is selected.
 */
-(void)tableView:(ExtendedTableView *)tableView menuWillAppear:(NSEvent *)theEvent
{
	int row = [articleList rowAtPoint:[articleList convertPoint:[theEvent locationInWindow] fromView:nil]];
	if (row >= 0)
	{
		// Select the row under the cursor if it isn't already selected
		if ([articleList numberOfSelectedRows] <= 1)
		{
			blockSelectionHandler = YES;
			[articleList selectRow:row byExtendingSelection:NO]; // Warning: this method has been deprecated.  Should be changed to selectRowIndexes:byExtendingSelection:
			[self refreshArticleAtCurrentRow:NO];
			blockSelectionHandler = NO;
		}
	}
}

/* selectFolderWithFilter
 * Switches to the specified folder and displays articles filtered by whatever is in
 * the search field.
 */
-(void)selectFolderWithFilter:(int)newFolderId
{
	[articleList deselectAll:self];
	currentSelectedRow = -1;
	[self setArticleListHeader];
	[articleController reloadArrayOfArticles];
	[articleController sortArticles];
	[articleList reloadData];
	if (guidOfArticleToSelect == nil)
		[articleList scrollRowToVisible:0];
	else
		[self selectArticleAfterReload];
}

/* refreshImmediatelyArticleAtCurrentRow
 * Refreshes the article at the current selected row.
 */
-(void)refreshImmediatelyArticleAtCurrentRow
{
	[self refreshArticlePane];
	
	// If we mark read after an interval, start the timer here.
	if (currentSelectedRow >= 0)
	{
		Article * theArticle = [[articleController allArticles] objectAtIndex:currentSelectedRow];
		if (![theArticle isRead] && !blockMarkRead)
		{
			[markReadTimer invalidate];
			[markReadTimer release];
			markReadTimer = nil;

			float interval = [[Preferences standardPreferences] markReadInterval];
			if (interval > 0 && !isAppInitialising)
				markReadTimer = [[NSTimer scheduledTimerWithTimeInterval:(double)interval
																  target:self
																selector:@selector(markCurrentRead:)
																userInfo:nil
																 repeats:NO] retain];
		}
	}
}

/* startSelectionChange
 * This is the function that is called on the timer to actually handle the
 * selection change.
 */
-(void)startSelectionChange:(NSTimer *)timer
{
	currentSelectedRow = [articleList selectedRow];
	[self refreshImmediatelyArticleAtCurrentRow];
}

/* refreshArticleAtCurrentRow
 * Refreshes the article at the current selected row.
 */
-(void)refreshArticleAtCurrentRow:(BOOL)delayFlag
{
	if (currentSelectedRow < 0)
		[articleText setHTML:@"<HTML></HTML>" withBase:@""];
	else
	{
		NSArray * allArticles = [articleController allArticles];
		NSAssert(currentSelectedRow < (int)[allArticles count], @"Out of range row index received");
		[selectionTimer invalidate];
		[selectionTimer release];
		selectionTimer = nil;

		float interval = [[Preferences standardPreferences] selectionChangeInterval];
		if (!testForKey(kShift) || !delayFlag )
			[self refreshImmediatelyArticleAtCurrentRow];
		else
			selectionTimer = [[NSTimer scheduledTimerWithTimeInterval:interval
															   target:self
															 selector:@selector(startSelectionChange:) 
															 userInfo:nil 
															  repeats:NO] retain];

		// Add this to the backtrack list
		NSString * guid = [[allArticles objectAtIndex:currentSelectedRow] guid];
		[articleController addBacktrack:guid];
	}
}

/* handleRefreshArticle
 * Respond to the notification to refresh the current article pane.
 */
-(void)handleRefreshArticle:(NSNotification *)nc
{
	if (!isAppInitialising)
		[self refreshArticlePane];
}

/* refreshArticlePane
 * Updates the article pane for the current selected articles.
 */
-(void)refreshArticlePane
{
	NSArray * msgArray = [self markedArticleRange];
	if ([msgArray count] == 0)
		[articleText setHTML:@"<HTML></HTML>" withBase:@""];
	else
	{
		NSString * htmlText = [articleText articleTextFromArray:msgArray];
		Article * firstArticle = [msgArray objectAtIndex:0];
		Folder * folder = [[Database sharedDatabase] folderFromID:[firstArticle folderId]];
		[articleText setHTML:htmlText withBase:SafeString([folder feedURL])];
	}
}

/* markCurrentRead
 * Mark the current article as read.
 */
-(void)markCurrentRead:(NSTimer *)aTimer
{
	if (currentSelectedRow != -1 && ![[Database sharedDatabase] readOnly])
	{
		Article * theArticle = [[articleController allArticles] objectAtIndex:currentSelectedRow];
		if (![theArticle isRead])
			[articleController markReadByArray:[NSArray arrayWithObject:theArticle] readFlag:YES];
	}
}

/* numberOfRowsInTableView [datasource]
 * Datasource for the table view. Return the total number of rows we'll display which
 * is equivalent to the number of articles in the current folder.
 */
-(int)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return [[articleController allArticles] count];
}

/* objectValueForTableColumn [datasource]
 * Called by the table view to obtain the object at the specified column and row. This is
 * called often so it needs to be fast.
 */
-(id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
	Database * db = [Database sharedDatabase];
	NSArray * allArticles = [articleController allArticles];
	Article * theArticle;
	
	NSParameterAssert(rowIndex >= 0 && rowIndex < (int)[allArticles count]);
	theArticle = [allArticles objectAtIndex:rowIndex];
	if ([[aTableColumn identifier] isEqualToString:MA_Field_Read])
	{
		if (![theArticle isRead])
			return [NSImage imageNamed:@"unread.tiff"];
		return [NSImage imageNamed:@"alphaPixel.tiff"];
	}
	if ([[aTableColumn identifier] isEqualToString:MA_Field_Flagged])
	{
		if ([theArticle isFlagged])
			return [NSImage imageNamed:@"flagged.tiff"];
		return [NSImage imageNamed:@"alphaPixel.tiff"];
	}
	if ([[aTableColumn identifier] isEqualToString:MA_Field_Comments])
	{
		if ([theArticle hasComments])
			return [NSImage imageNamed:@"comments.tiff"];
		return [NSImage imageNamed:@"alphaPixel.tiff"];
	}
	if ([[aTableColumn identifier] isEqualToString:MA_Field_Date])
	{
		return [[theArticle articleData] objectForKey:[aTableColumn identifier]];
	}
	if ([[aTableColumn identifier] isEqualToString:MA_Field_Headlines])
	{
		NSMutableAttributedString * theAttributedString = [[NSMutableAttributedString alloc] init];
		BOOL isSelectedRow = [aTableView isRowSelected:rowIndex] && ([[NSApp mainWindow] firstResponder] == aTableView);

		if ([[db fieldByName:MA_Field_Subject] visible])
		{
			NSDictionary * topLineDictPtr;

			if ([theArticle isRead])
				topLineDictPtr = (isSelectedRow ? selectionDict : topLineDict);
			else
				topLineDictPtr = (isSelectedRow ? unreadTopLineSelectionDict : unreadTopLineDict);
			NSString * topString = [NSString stringWithFormat:@"%@\n", [theArticle title]];
			[theAttributedString appendAttributedString:[[[NSAttributedString alloc] initWithString:topString attributes:topLineDictPtr] autorelease]];
		}

		// Add the summary line that appears below the title.
		if ([[db fieldByName:MA_Field_Summary] visible])
		{
			NSString * summaryString = [theArticle summary];
			int maxSummaryLength = MIN([summaryString length], 80);
			NSString * middleString = [NSString stringWithFormat:@"%@\n", [summaryString substringToIndex:maxSummaryLength]];
			NSDictionary * middleLineDictPtr = (isSelectedRow ? selectionDict : middleLineDict);
			[theAttributedString appendAttributedString:[[[NSAttributedString alloc] initWithString:middleString attributes:middleLineDictPtr] autorelease]];
		}
		
		// Add the link line that appears below the summary and title.
		if ([[db fieldByName:MA_Field_Link] visible])
		{
			NSString * linkString = [NSString stringWithFormat:@"%@\n", [theArticle link]];
			NSDictionary * linkLineDictPtr = (isSelectedRow ? selectionDict : linkLineDict);
			[linkLineDict setObject:[NSURL URLWithString:[theArticle link]] forKey:NSLinkAttributeName];
			[theAttributedString appendAttributedString:[[[NSAttributedString alloc] initWithString:linkString attributes:linkLineDictPtr] autorelease]];
		}
		
		// Create the detail line that appears at the bottom.
		NSDictionary * bottomLineDictPtr = (isSelectedRow ? selectionDict : bottomLineDict);
		NSMutableString * summaryString = [NSMutableString stringWithString:@""];
		NSString * delimiter = @"";

		if ([[db fieldByName:MA_Field_Folder] visible])
		{
			Folder * folder = [db folderFromID:[theArticle folderId]];
			[summaryString appendString:[folder name]];
			delimiter = @" - ";
		}
		if ([[db fieldByName:MA_Field_Date] visible])
		{
			NSCalendarDate * anDate = [[theArticle date] dateWithCalendarFormat:nil timeZone:nil];
			[summaryString appendFormat:@"%@%@", delimiter,[anDate friendlyDescription]];
			delimiter = @" - ";
		}
		if ([[db fieldByName:MA_Field_Author] visible])
		{
			if (![[theArticle author] isBlank])
				[summaryString appendFormat:@"%@%@", delimiter, [theArticle author]];
		}
		[theAttributedString appendAttributedString:[[[NSAttributedString alloc] initWithString:summaryString attributes:bottomLineDictPtr] autorelease]];
		return [theAttributedString autorelease];
	}

	// Only string articleData objects should make it from here.
	NSString * cellString;
	if (![[aTableColumn identifier] isEqualToString:MA_Field_Folder])
		cellString = [[theArticle articleData] objectForKey:[aTableColumn identifier]];
	else
	{
		Folder * folder = [db folderFromID:[theArticle folderId]];
		cellString = [folder name];
	}

	// Return the cell string with a paragraph style that will truncate over-long strings by placing
	// ellipsis in the middle to fit within the cell.
    static NSDictionary * info = nil;
    if (info == nil)
	{
        NSMutableParagraphStyle * style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
        [style setLineBreakMode:NSLineBreakByTruncatingTail];
        info = [[NSDictionary alloc] initWithObjectsAndKeys:style, NSParagraphStyleAttributeName, nil];
        [style release];
    }
    return [[[NSAttributedString alloc] initWithString:cellString attributes:info] autorelease];
}

/* willDisplayCell [delegate]
 * Catch the table view before it displays a cell.
 */
-(void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
	if (tableLayout == MA_Layout_Report)
	{
		if (![aCell isKindOfClass:[NSImageCell class]])
		{
			[aCell setTextColor:[NSColor blackColor]];
			Article * theArticle = [[articleController allArticles] objectAtIndex:rowIndex];
			if (![theArticle isRead])
				[aCell setFont:articleListUnreadFont];
			else
				[aCell setFont:articleListFont];
		}
	}
}

/* tableViewSelectionDidChange [delegate]
 * Handle the selection changing in the table view unless blockSelectionHandler is set.
 */
-(void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
	if (!blockSelectionHandler)
	{
		currentSelectedRow = [articleList selectedRow];
		[self refreshArticleAtCurrentRow:YES];
	}
}

/* didClickTableColumns
 * Handle the user click in the column header to sort by that column.
 */
-(void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn
{
	NSString * columnName = [tableColumn identifier];
	[articleController sortByIdentifier:columnName];
}

/* tableViewColumnDidResize
 * This notification is called when the user completes resizing a column. We obtain the
 * new column size and save the settings.
 */
-(void)tableViewColumnDidResize:(NSNotification *)notification
{
	if (!isInTableInit && !isAppInitialising && !isChangingOrientation)
	{
		NSTableColumn * tableColumn = [[notification userInfo] objectForKey:@"NSTableColumn"];
		Field * field = [[Database sharedDatabase] fieldByName:[tableColumn identifier]];
		int oldWidth = [[[notification userInfo] objectForKey:@"NSOldWidth"] intValue];
		
		if (oldWidth != [tableColumn width])
		{
			[field setWidth:[tableColumn width]];
			[self saveTableSettings];
		}
	}
}

/* writeRows
 * Called to initiate a drag from MessageListView. Use the common copy selection code to copy to
 * the pasteboard.
 */
-(BOOL)tableView:(NSTableView *)tv writeRows:(NSArray *)rows toPasteboard:(NSPasteboard *)pboard
{
	return [self copyTableSelection:rows toPasteboard:pboard];
}

/* copyTableSelection
 * This is the common copy selection code. We build an array of dictionary entries each of
 * which include details of each selected article in the standard RSS item format defined by
 * Ranchero NetNewsWire. See http://ranchero.com/netnewswire/rssclipboard.php for more details.
 */
-(BOOL)copyTableSelection:(NSArray *)rows toPasteboard:(NSPasteboard *)pboard
{
	NSMutableArray * arrayOfArticles = [[NSMutableArray alloc] init];
	NSMutableString * fullHTMLText = [[NSMutableString alloc] init];
	NSMutableString * fullPlainText = [[NSMutableString alloc] init];
	Database * db = [Database sharedDatabase];
	int count = [rows count];
	int index;
	
	// Set up the pasteboard
	[pboard declareTypes:[NSArray arrayWithObjects:MA_PBoardType_RSSItem, NSStringPboardType, NSHTMLPboardType, nil] owner:self];
	
	// Open the HTML string
	[fullHTMLText appendString:@"<html><body>"];
	
	// Get all the articles that are being dragged
	for (index = 0; index < count; ++index)
	{
		int msgIndex = [[rows objectAtIndex:index] intValue];
		Article * thisArticle = [[articleController allArticles] objectAtIndex:msgIndex];
		Folder * folder = [db folderFromID:[thisArticle folderId]];
		NSString * msgText = [thisArticle body];
		NSString * msgTitle = [thisArticle title];
		NSString * msgLink = [thisArticle link];

		NSMutableDictionary * articleDict = [[NSMutableDictionary alloc] init];
		[articleDict setValue:msgTitle forKey:@"rssItemTitle"];
		[articleDict setValue:msgLink forKey:@"rssItemLink"];
		[articleDict setValue:msgText forKey:@"rssItemDescription"];
		[articleDict setValue:[folder name] forKey:@"sourceName"];
		[articleDict setValue:[folder homePage] forKey:@"sourceHomeURL"];
		[articleDict setValue:[folder feedURL] forKey:@"sourceRSSURL"];
		[arrayOfArticles addObject:articleDict];
		[articleDict release];

		// Plain text
		[fullPlainText appendFormat:@"%@\n%@\n\n", msgTitle, msgText];
		
		// Add HTML version too.
		[fullHTMLText appendFormat:@"<a href=\"%@\">%@</a><br />%@<br /><br />", msgLink, msgTitle, msgText];
	}
	
	// Close the HTML string
	[fullHTMLText appendString:@"</body></html>"];

	// Put string on the pasteboard for external drops.
	[pboard setPropertyList:arrayOfArticles forType:MA_PBoardType_RSSItem];
	[pboard setString:fullPlainText forType:NSStringPboardType];
	[pboard setString:[fullHTMLText stringByEscapingExtendedCharacters] forType:NSHTMLPboardType];

	[arrayOfArticles release];
	[fullHTMLText release];
	[fullPlainText release];
	return YES;
}

/* markedArticleRange
 * Retrieve an array of selected articles.
 */
-(NSArray *)markedArticleRange
{
	NSMutableArray * articleArray = nil;
	if ([articleList numberOfSelectedRows] > 0)
	{
		NSEnumerator * enumerator = [articleList selectedRowEnumerator];
		NSNumber * rowIndex;

		articleArray = [NSMutableArray arrayWithCapacity:16];
		while ((rowIndex = [enumerator nextObject]) != nil)
			[articleArray addObject:[[articleController allArticles] objectAtIndex:[rowIndex intValue]]];
	}
	return articleArray;
}

/* dealloc
 * Clean up behind ourself.
 */
-(void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[extDateFormatter release];
	[selectionTimer release];
	[markReadTimer release];
	[articleListFont release];
	[articleListUnreadFont release];
	[guidOfArticleToSelect release];
	[unreadTopLineSelectionDict release];
	[selectionDict release];
	[unreadTopLineDict release];
	[topLineDict release];
	[middleLineDict release];
	[linkLineDict release];
	[bottomLineDict release];
	[super dealloc];
}
@end
