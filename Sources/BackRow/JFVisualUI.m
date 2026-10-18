#import "JFVisualUI.h"
#import "JFBackRow.h"
#import "JFPosterTrace.h"
#import "JFBRMenu.h"
#import "Navigation/JFArtwork.h"
#import "Navigation/JFBrowser.h"
#import "Navigation/JFDetailMetadata.h"
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#include <math.h>
#include <string.h>

static void JFFill(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat alpha, CGRect rect) {
    CGContextSetRGBFillColor(c,r,g,b,alpha); CGContextFillRect(c,rect);
}
static void JFRound(CGContextRef c, CGRect rect, CGFloat radius) {
    CGFloat x=rect.origin.x,y=rect.origin.y,w=rect.size.width,h=rect.size.height;
    CGFloat r=fmin(radius,fmin(w,h)/2);
    CGContextBeginPath(c); CGContextMoveToPoint(c,x+r,y);
    CGContextAddArcToPoint(c,x+w,y,x+w,y+h,r);
    CGContextAddArcToPoint(c,x+w,y+h,x,y+h,r);
    CGContextAddArcToPoint(c,x,y+h,x,y,r);
    CGContextAddArcToPoint(c,x,y,x+w,y,r);
    CGContextClosePath(c);
}
static void JFBox(CGContextRef c,CGRect r,CGFloat radius,BOOL focused) {
    // Keep the card/button fill neutral; selection is a cyan OUTLINE only.
    CGContextSetRGBFillColor(c,0.13,0.13,0.15,0.94);
    JFRound(c,r,radius);CGContextFillPath(c);
    if (focused) { CGContextSetRGBStrokeColor(c,0.08,0.75,0.96,1);
        CGContextSetLineWidth(c,4.0);JFRound(c,CGRectInset(r,2,2),radius);CGContextStrokePath(c); }
}
static void JFText(CGContextRef c,NSString *text,CGFloat x,CGFloat y,CGFloat size,CGFloat shade) {
    if (![text isKindOfClass:[NSString class]] || !text.length) return;
    CTFontRef font=CTFontCreateWithName(CFSTR("STHeitiSC-Medium"),size,NULL);
    if (!font) font=CTFontCreateWithName(CFSTR("HelveticaNeue"),size,NULL);
    if (!font) return;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat comps[]={shade,shade,shade,1};
    CGColorRef color=CGColorCreate(space,comps);
    NSDictionary *attrs=@{(id)kCTFontAttributeName:(id)font,(id)kCTForegroundColorAttributeName:(id)color};
    NSAttributedString *at=[[[NSAttributedString alloc] initWithString:text attributes:attrs] autorelease];
    CTLineRef line=CTLineCreateWithAttributedString((CFAttributedStringRef)at);
    CGContextSetTextMatrix(c,CGAffineTransformIdentity);CGContextSetTextPosition(c,x,y);CTLineDraw(line,c);
    CFRelease(line);CFRelease(font);CGColorRelease(color);CGColorSpaceRelease(space);
}
static NSString *JFClip(NSString *s,NSUInteger n) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return s.length>n?[[s substringToIndex:n-1] stringByAppendingString:@"…"]:s;
}
static CGImageRef JFDecode(NSData *bytes) {
    if (!bytes.length)return NULL;
    CGImageSourceRef src=CGImageSourceCreateWithData((CFDataRef)bytes,NULL);
    if (!src)return NULL;
    CGImageRef image=CGImageSourceCreateImageAtIndex(src,0,NULL);CFRelease(src);return image;
}
static void JFImage(CGContextRef c,CGImageRef image,CGRect rect,BOOL fill,CGFloat corner) {
    if (!image || rect.size.height<=0||rect.size.width<=0)return;
    CGContextSaveGState(c);
    if (corner>0) {JFRound(c,rect,corner);CGContextClip(c);} else CGContextClipToRect(c,rect);
    CGFloat iw=CGImageGetWidth(image),ih=CGImageGetHeight(image);
    CGFloat scale=fill?fmax(rect.size.width/iw,rect.size.height/ih):fmin(rect.size.width/iw,rect.size.height/ih);
    CGSize size=CGSizeMake(iw*scale,ih*scale);
    CGRect target=CGRectMake(rect.origin.x+(rect.size.width-size.width)/2,
        rect.origin.y+(rect.size.height-size.height)/2,size.width,size.height);
    CGContextDrawImage(c,target,image);CGContextRestoreGState(c);
}
static void JFAsset(CGContextRef c,JFArtwork *art,NSString *identifier,NSString *type,NSUInteger px,CGRect r,BOOL fill,CGFloat round) {
    if (![identifier isKindOfClass:[NSString class]]||!identifier.length)return;
    CGImageRef image=[art copyImageForID:identifier type:type width:px];
    if (image) {JFImage(c,image,r,fill,round);CGImageRelease(image);}
}
static void JFParagraph(CGContextRef c,NSString *s,CGRect area,CGFloat size) {
    if (!s.length)return;
    CTFontRef font=CTFontCreateWithName(CFSTR("STHeitiSC-Light"),size,NULL);
    if (!font)font=CTFontCreateWithName(CFSTR("HelveticaNeue"),size,NULL);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat comps[]={0.84,0.84,0.85,1};
    CGColorRef color=CGColorCreate(space,comps);
    CGFloat spacing=6;
    CTParagraphStyleSetting setting={kCTParagraphStyleSpecifierLineSpacingAdjustment,sizeof(spacing),&spacing};
    CTParagraphStyleRef p=CTParagraphStyleCreate(&setting,1);
    NSDictionary *attrs=@{(id)kCTFontAttributeName:(id)font,(id)kCTForegroundColorAttributeName:(id)color,
                          (id)kCTParagraphStyleAttributeName:(id)p};
    NSAttributedString *str=[[[NSAttributedString alloc]initWithString:s attributes:attrs]autorelease];
    CTFramesetterRef setter=CTFramesetterCreateWithAttributedString((CFAttributedStringRef)str);
    CGPathRef path=CGPathCreateWithRect(area,NULL);
    CTFrameRef frame=CTFramesetterCreateFrame(setter,CFRangeMake(0,0),path,NULL);
    CGContextSetTextMatrix(c,CGAffineTransformIdentity);CTFrameDraw(frame,c);
    CFRelease(frame);CGPathRelease(path);CFRelease(setter);CGColorRelease(color);CGColorSpaceRelease(space);CFRelease(font);CFRelease(p);
}
static CGFloat JFDescriptionHeight(NSString *source,CGFloat width,CGFloat fontSize) {
    if(![source isKindOfClass:[NSString class]]||!source.length)return 0;
    CTFontRef font=CTFontCreateWithName(CFSTR("STHeitiSC-Light"),fontSize,NULL);
    if(!font)font=CTFontCreateWithName(CFSTR("HelveticaNeue"),fontSize,NULL);
    if(!font)return 0;
    CGFloat spacing=6;
    CTParagraphStyleSetting setting={kCTParagraphStyleSpecifierLineSpacingAdjustment,sizeof(spacing),&spacing};
    CTParagraphStyleRef style=CTParagraphStyleCreate(&setting,1);
    NSAttributedString *as=[[[NSAttributedString alloc]initWithString:source
        attributes:@{(id)kCTFontAttributeName:(id)font,
                     (id)kCTParagraphStyleAttributeName:(id)style}] autorelease];
    CTFramesetterRef frames=CTFramesetterCreateWithAttributedString((CFAttributedStringRef)as);
    CGSize size=CTFramesetterSuggestFrameSizeWithConstraints(frames,
        CFRangeMake(0,0),NULL,CGSizeMake(width,100000),NULL);
    CFRelease(frames);CFRelease(style);CFRelease(font);
    return fmin(30000,ceil(size.height+14));
}
static BOOL JFFrame(id host,CGRect *frame) {
    SEL selector=NSSelectorFromString(@"bounds");
    NSMethodSignature *sig=[host methodSignatureForSelector:selector];
    if (!sig||strcmp(sig.methodReturnType,@encode(CGRect))||sig.numberOfArguments!=2)return NO;
    NSInvocation *v=[NSInvocation invocationWithMethodSignature:sig];
    v.target=host;v.selector=selector;[v invoke];[v getReturnValue:frame];
    return frame->size.width>0&&frame->size.height>0;
}
static BOOL JFSetFrame(id obj,CGRect frame) {
    if (!obj)return NO;
    SEL selector=NSSelectorFromString(@"setFrame:");
    NSMethodSignature *sig=[obj methodSignatureForSelector:selector];
    if(!sig||strcmp(sig.methodReturnType,@encode(void))||sig.numberOfArguments!=3||
        strcmp([sig getArgumentTypeAtIndex:2],@encode(CGRect)))return NO;
    NSInvocation *v=[NSInvocation invocationWithMethodSignature:sig];
    v.target=obj;v.selector=selector;[v setArgument:&frame atIndex:2];[v invoke];return YES;
}
static void JFDrawHeader(CGContextRef c,JFArtwork *art,NSString *user,
                          NSString *leftAction,NSString *rightAction,BOOL leftFocus,BOOL rightFocus) {
    JFFill(c,0.075,0.075,0.082,0.98,CGRectMake(0,651,1280,69));
    // Display the installed Jellyfin app icon, not a placeholder glyph.
    static CGImageRef brand=NULL; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle=[NSBundle bundleWithIdentifier:@"org.jellyfin.atv3"];
        NSString *path=[bundle pathForResource:@"AppIcon" ofType:@"png"];
        if(!path.length)path=@"/Applications/Jellyfin.frappliance/AppIcon.png";
        brand=JFDecode([NSData dataWithContentsOfFile:path]);
    });
    if(brand)JFImage(c,brand,CGRectMake(22,660,46,46),NO,0);
    else JFText(c,@"◈",28,674,29,0.96);
    JFText(c,@"jellyfin",78,674,27,0.96);
    // Jellyfin account has no custom avatar at the moment. Draw a native
    // profile silhouette instead of showing the account name as a text label.
    CGRect avatar=CGRectMake(1184,657,51,51);
    JFFill(c,0.03,0.03,0.04,1,CGRectMake(1181,653,58,58));
    CGContextSetRGBFillColor(c,0.04,0.48,0.66,1);
    CGContextFillEllipseInRect(c,avatar);
    CGImageRef account=[art copyImageForID:@"me" type:@"Avatar" width:84];
    if(account){JFImage(c,account,avatar,YES,26);CGImageRelease(account);}
    else {
        CGContextSaveGState(c);JFRound(c,avatar,26);CGContextClip(c);
        CGContextSetRGBFillColor(c,1,1,1,0.98);
        CGContextFillEllipseInRect(c,CGRectMake(1201,684,17,17));
        CGContextFillEllipseInRect(c,CGRectMake(1191,655,37,26));
        CGContextRestoreGState(c);
    }
    if(leftAction.length) {
        CGRect left=CGRectMake(806,664,169,40);
        JFBox(c,left,8,leftFocus);JFText(c,leftAction,819,675,18,0.98);
    }
    if(rightAction.length) {
        CGRect right=CGRectMake(991,664,170,40);
        JFBox(c,right,8,rightFocus);JFText(c,rightAction,1005,675,18,0.98);
    }
}
// Libraries are two wide, 16:7-ish cards per row. Keep this one geometry
// shared by the raster background, native images, and animated focus outline.
static CGRect JFLibraryCardRect(NSInteger index,NSInteger firstRow) {
    CGFloat x=110+(index%2)*555;
    CGFloat top=607-(index/2-firstRow)*285;
    return CGRectMake(x,top-230,505,230);
}
static const NSInteger JFLibraryColumns=2;
static const NSInteger JFLibraryVisibleRows=2;
static void JFDrawLibrary(CGContextRef c,NSDictionary *snapshot,NSArray *rows,long selected,NSInteger firstRow,JFArtwork *art,NSString *user,BOOL tiles) {
    NSArray *libraries=snapshot[@"libraries"];NSInteger count=(NSInteger)libraries.count;
    for(NSInteger i=firstRow*JFLibraryColumns;i<count &&
                    i<(firstRow+JFLibraryVisibleRows)*JFLibraryColumns;i++) {
        NSDictionary *item=libraries[(NSUInteger)i];
        CGRect rect=JFLibraryCardRect(i,firstRow);
        JFBox(c,CGRectInset(rect,-3,-3),13,selected==i);
        NSDictionary *tags=[item[@"ImageTags"] isKindOfClass:[NSDictionary class]]?item[@"ImageTags"]:@{};
        NSString *type=[tags[@"Primary"] isKindOfClass:[NSString class]]?@"Primary":
                       ([tags[@"Thumb"] isKindOfClass:[NSString class]]?@"Thumb":@"Primary");
        if(!tiles)JFAsset(c,art,item[@"Id"],type,400,rect,YES,10);
        NSString *name=item[@"Name"];
        JFText(c,JFClip(name,38),rect.origin.x+5,rect.origin.y-29,22,0.92);
    }
    if (!libraries.count)JFText(c,@"No libraries available",76,450,29,0.8);
    JFDrawHeader(c,art,user,@"Refresh",@"Sign out",selected==count,selected==count+1);
}
static void JFDrawMedia(CGContextRef c,NSDictionary *snapshot,NSArray *rows,long selected,NSInteger firstRow,
                         JFArtwork *art,NSString *user,BOOL search,NSString *query,BOOL tiles,
                         BOOL chromeOnly) {
    NSInteger n=(NSInteger)rows.count;
    NSInteger start=search?1:0;
    NSInteger end=n-(search?1:2);
    if(end<start)end=start;
    // Disabled empty-state rows are not media tiles.
    if (end>start && ![rows[(NSUInteger)(end-1)][@"action"] isEqual:@"media"])end--;
    NSInteger count=end-start;
    if(search) {
        JFFill(c,0.03,0.03,0.035,0.94,CGRectMake(0,0,1280,649));
        JFBox(c,CGRectMake(104,558,1069,65),10,selected==0);
        JFText(c,query.length?JFClip(query,65):@"Select here to search this library",126,582,25,0.98);
        JFText(c,[NSString stringWithFormat:@"Search results: %ld",(long)count],106,518,21,0.78);
    }
    // Queue focused artwork before the other visible 9 thumbnails.
    if(selected>=start && selected<end) {
        NSString *focusID=rows[(NSUInteger)selected][@"itemID"];
        CGImageRef focus=[art copyImageForID:focusID type:@"Primary" width:400];
        if(focus)CGImageRelease(focus);
    }
    NSInteger rowsVisible=search?1:2;
    CGFloat top=search?485:644;
    CGFloat step=search?320:310;
    for(NSInteger i=firstRow*5;i<count && i<(firstRow+rowsVisible)*5;i++) {
        NSInteger j=i+start;
        NSDictionary *row=rows[(NSUInteger)j];
        NSString *ident=row[@"itemID"];
        CGFloat x=41+(i%5)*248;
        CGFloat y=top-(i/5-firstRow)*step-250;
        CGRect rect=CGRectMake(x,y,201,250);
        // All covers are native layers. Never rasterize empty placeholder
        // boxes into the shared chrome used by a two-show TV library.
        if(!tiles) {
            JFBox(c,CGRectInset(rect,-4,-4),0,selected==j);
            JFAsset(c,art,ident,@"Primary",400,rect,YES,0);
        }
        if(!chromeOnly) {
            JFText(c,JFClip(row[@"name"]?:row[@"title"],14),x+1,y-28,19,0.96);
            NSString *year=[row[@"year"] description];if(year.length&&![year isEqual:@"0"])
                JFText(c,year,x+1,y-53,17,0.7);
        }
    }
    if (!count)JFText(c,search?@"No results":@"This library is empty",110,405,26,0.76);
    NSInteger backIndex=search?(NSInteger)[rows count]-1:(NSInteger)[rows count]-2;
    NSInteger searchIndex=search?0:(NSInteger)[rows count]-1;
    JFDrawHeader(c,art,user,@"Back",search?@"Close":@"Search",
                 selected==backIndex,selected==searchIndex);
}
static void JFDrawDetail(CGContextRef c,NSDictionary *snapshot,NSArray *rows,long selected,
                          JFArtwork *art,NSData *poster,CGFloat scroll,BOOL nativePoster) {
    NSDictionary *detail=snapshot[@"detail"];NSString *ident=detail[@"Id"];
    // Request Logo before the large backdrop so the headline appears early.
    CGImageRef logo=[art copyImageForID:ident type:@"Logo" width:630];
    CGImageRef backdrop=[art copyImageForID:ident type:@"Backdrop" width:1280];
    if(backdrop){JFImage(c,backdrop,CGRectMake(0,0,1280,720),YES,0);CGImageRelease(backdrop);}
    JFFill(c,0.015,0.015,0.018,0.70,CGRectMake(0,0,1280,720));
    JFFill(c,0.025,0.025,0.031,0.67,CGRectMake(0,0,1280,416));
    // Fixed poster: substantially taller, bottom margin of only 24 pixels.
    CGRect posterRect=CGRectMake(43,24,324,466);
    JFBox(c,CGRectInset(posterRect,-2,-2),0,NO);
    if(!nativePoster) {
        CGImageRef pic=[art copyImageForID:ident type:@"Primary" width:400];
        if(!pic)pic=JFDecode(poster);
        if(pic){JFImage(c,pic,posterRect,NO,0);CGImageRelease(pic);}
    }
    CGContextSaveGState(c);
    CGContextClipToRect(c,CGRectMake(408,0,872,720));
    CGContextTranslateCTM(c,0,scroll);
    if(logo){JFImage(c,logo,CGRectMake(492,531,658,157),NO,0);CGImageRelease(logo);}
    JFText(c,JFClip(detail[@"Name"],42),432,496,27,1);
    // All rows have aligned left/right edges: x=430 ... x=1214.
    const CGFloat left=430, paneWidth=784, gap=12;
    NSInteger button=0;CGFloat nextTop=405;
    NSString *facts=JFDetailFacts(detail)?:@"",*genres=JFDetailGenres(detail)?:@"";
    NSString *overview=[detail[@"Overview"] isKindOfClass:[NSString class]]?detail[@"Overview"]:@"";
    NSString *description=overview.length?overview:@"No description available";
    for(NSUInteger i=0;i<rows.count;i++) {
        NSDictionary *row=rows[i];NSString *action=row[@"action"];CGRect rect=CGRectZero;
        if(button<3) {
            CGFloat width=(paneWidth-2*gap)/3;
            rect=CGRectMake(left+button*(width+gap),420,width,58);
            button++;
        } else if([action isEqual:@"subtitle"] || [action isEqual:@"audio"]) {
            rect=CGRectMake(left,nextTop-58,paneWidth,58);
            nextTop=rect.origin.y-15;
        } else if([action isEqual:@"info"]) {
            CGFloat para=JFDescriptionHeight(description,paneWidth-40,20);
            CGFloat h=MAX(158,108+para+22);
            CGRect info=CGRectMake(left,nextTop-h,paneWidth,h);
            JFBox(c,info,9,selected==(long)i);
            CGFloat top=nextTop;
            JFText(c,JFClip(facts,75),left+21,top-35,19,0.98);
            JFText(c,JFClip(genres,73),left+21,top-69,18,0.77);
            JFParagraph(c,description,CGRectMake(left+21,info.origin.y+19,
                paneWidth-42,h-115),20);
            continue;
        } else continue;
        JFBox(c,rect,9,selected==(long)i);
        JFText(c,JFClip(row[@"title"],([action isEqual:@"subtitle"]||[action isEqual:@"audio"])?64:19),
               rect.origin.x+18,rect.origin.y+19,20,1);
    }
    CGContextRestoreGState(c);
}

// This scene contains ONLY background, navigation text and the currently
// visible item labels. Posters/focus are native BackRow layers on the UI thread.
// CoreGraphics + CoreText JPEG work is done on an isolated background queue.
static NSData *JFGridScene(NSDictionary *snapshot,NSArray *rows,NSInteger firstRow,
                           NSString *username,BOOL search,NSString *query,
                           BOOL chromeOnly) {
    NSInteger page=[snapshot[@"page"] integerValue];
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef c=CGBitmapContextCreate(NULL,1024,576,8,1024*4,space,
                        kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if(!c)return nil;
    CGContextScaleCTM(c,0.8,0.8);
    JFFill(c,0.055,0.055,0.059,1,CGRectMake(0,0,1280,720));
    if(page==JFLibrariesPage)
        JFDrawLibrary(c,snapshot,rows,-1,firstRow,nil,username,YES);
    else
        JFDrawMedia(c,snapshot,rows,-1,chromeOnly?0:firstRow,
                    nil,username,search,query,YES,chromeOnly);
    CGImageRef frame=CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    if(!frame)return nil;
    NSMutableData *out=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData(
        (CFMutableDataRef)out,CFSTR("public.jpeg"),1,NULL);
    if(destination) {
        CGImageDestinationAddImage(destination,frame,(CFDictionaryRef)@{
            (id)kCGImageDestinationLossyCompressionQuality:@0.78});
        CGImageDestinationFinalize(destination);CFRelease(destination);
    }
    CGImageRelease(frame);
    return out.length?[out copy]:nil;
}
// A pure scene key is shared by actual rendering and idle-ahead pre-render.
static NSString *JFGridKey(NSDictionary *snapshot,NSArray *rows,NSString *scope,
                            NSInteger firstRow,BOOL search,NSString *query) {
    NSInteger page=[snapshot[@"page"] integerValue],mediaCount=0;
    for(NSDictionary *row in rows)
        if([row[@"action"] isEqual:@"media"])mediaCount++;
    NSMutableString *labels=[NSMutableString string];
    if(page==JFLibrariesPage) {
        NSArray *all=snapshot[@"libraries"];
        for(NSInteger i=firstRow*JFLibraryColumns;i<(NSInteger)all.count &&
                i<(firstRow+JFLibraryVisibleRows)*JFLibraryColumns;i++)
            [labels appendFormat:@"%@,",all[(NSUInteger)i][@"Name"]?:@""];
    } else {
        NSInteger first=firstRow*5,limit=MIN(mediaCount,first+(search?5:10));
        for(NSInteger i=first;i<limit;i++) {
            NSUInteger pos=(NSUInteger)(i+(search?1:0));
            if(pos>=rows.count)break;
            NSDictionary *r=rows[pos];
            [labels appendFormat:@"%@:%@,",r[@"name"]?:r[@"title"]?:@"",r[@"year"]?:@""];
        }
    }
    return [NSString stringWithFormat:@"%@|%ld|0|%ld|%@|%@|%@|0|0",
        scope,(long)firstRow,(long)mediaCount,rows.count?rows[0][@"title"]:@"",
        query?:@"",labels];
}
@implementation JFVisualUI
+ (CGFloat)maxScrollForDetail:(NSDictionary *)detail rows:(NSArray *)rows {
    if(![detail isKindOfClass:[NSDictionary class]])return 0;
    NSString *overview=[detail[@"Overview"] isKindOfClass:[NSString class]]?detail[@"Overview"]:@"";
    if(!overview.length)overview=@"No description available";
    CGFloat measured=JFDescriptionHeight(overview,784-40,20);
    CGFloat height=MAX(158,108+measured+22);
    NSUInteger options=0;
    for(NSDictionary *row in rows) {
        NSString *kind=row[@"action"];
        if([kind isEqual:@"subtitle"]||[kind isEqual:@"audio"])options++;
    }
    // Info panel top = 405 - 73*optionCount. Content bottom must remain >=24.
    CGFloat panelTop=405-73*options;
    return MAX(0,height-panelTop+24);
}
static CGRect JFFocusRect(NSInteger page,NSArray *rows,NSDictionary *snapshot,
                          NSInteger index,NSInteger firstRow,BOOL search,CGFloat scroll) {
    if(index<0 || (NSUInteger)index>=rows.count)return CGRectZero;
    NSDictionary *row=rows[(NSUInteger)index];
    NSString *action=row[@"action"];
    if(page==JFLibrariesPage) {
        NSInteger n=[snapshot[@"libraries"] count];
        if([action isEqual:@"refresh"])return CGRectMake(806,664,169,40);
        if([action isEqual:@"logout"])return CGRectMake(991,664,170,40);
        if(index<n && index/JFLibraryColumns>=firstRow &&
           index/JFLibraryColumns<firstRow+JFLibraryVisibleRows)
            return CGRectInset(JFLibraryCardRect(index,firstRow),-3,-3);
        return CGRectZero;
    }
    if(page==JFDetailPage) {
        if(index<3) {
            CGFloat width=(784-24)/3.;
            return CGRectMake(430+index*(width+12),420+scroll,width,58);
        }
        NSUInteger options=0,preceding=0;
        for(NSInteger i=3;i<index;i++)
            if([@[@"subtitle",@"audio"] containsObject:rows[(NSUInteger)i][@"action"]]) preceding++;
        if([@[@"subtitle",@"audio"] containsObject:action])
            return CGRectMake(430,405-73*preceding-58+scroll,784,58);
        if([action isEqual:@"info"]) {
            for(NSDictionary *r in rows)
                if([@[@"subtitle",@"audio"] containsObject:r[@"action"]])options++;
            NSString *desc=snapshot[@"detail"][@"Overview"];
            if(![desc isKindOfClass:[NSString class]]||!desc.length)desc=@"No description available";
            CGFloat height=MAX(158,108+JFDescriptionHeight(desc,744,20)+22);
            CGRect box=CGRectMake(430,405-73*options-height+scroll,784,height);
            // The control is scrollable; outline only the visible portion.
            return CGRectIntersection(box,CGRectMake(430,0,784,720));
        }
        return CGRectZero;
    }
    if([action isEqual:@"back"])return CGRectMake(806,664,169,40);
    if([action isEqual:@"search"]||[action isEqual:@"search-close"])return CGRectMake(991,664,170,40);
    if([action isEqual:@"search-edit"])return CGRectMake(104,558,1069,65);
    if([action isEqual:@"media"]) {
        NSInteger start=search?1:0, cell=index-start;
        if(cell<0 || cell/5<firstRow || cell/5>=firstRow+(search?1:2))return CGRectZero;
        CGFloat x=41+(cell%5)*248, top=search?485:644, step=search?320:310;
        CGFloat y=top-(cell/5-firstRow)*step-250;
        return CGRectInset(CGRectMake(x,y,201,250),-4,-4);
    }
    return CGRectZero;
}
static void JFSetFloat(id control,NSString *name,float value) {
    SEL selector=NSSelectorFromString(name);
    if(JFBRHas(control,name,@encode(void),@[[NSString stringWithUTF8String:@encode(float)]]))
        ((void(*)(id,SEL,float))objc_msgSend)(control,selector,value);
}
- (id)initWithController:(id)controller {
    if((self=[super init])) {
        _host=controller;_visibleFirstRow=0;_focusFrame=CGRectZero;
        _loginFocusTransition=YES;
        _sceneQueue=dispatch_queue_create("org.jellyfin.atv3.grid-scene",DISPATCH_QUEUE_SERIAL);
        _sceneCache=[NSMutableDictionary new];_sceneOrder=[NSMutableArray new];
    }
    return self;
}
- (BOOL)usingNativeFocus {return _surface!=nil && _focus!=nil && !_closed;}
- (void)hide {
    if(_surface)JFSetFrame(_surface,CGRectZero);
    if(_focus) {
        CALayer *focusLayer=JFBRObject(_focus,@"layer");
        if([focusLayer isKindOfClass:[CALayer class]]) {
            [focusLayer removeAnimationForKey:@"JFInitialFocus"];
            focusLayer.opacity=0;
        }
        JFSetFrame(_focus,CGRectZero);
    }
    _loginFocusTransition=YES;
    _focusFrame=CGRectZero; // subsequent login must rebuild focus geometry
    if(_detailPoster)JFSetFrame(_detailPoster,CGRectZero);
    if(_captionHost)JFSetFrame(_captionHost,CGRectZero);
    [self hideNativeCaptions];
    for(id tile in _tiles)JFSetFrame(tile,CGRectZero);
    [_lastDrawKey release];_lastDrawKey=nil;
    @synchronized(self) {[_pendingSceneKey release];_pendingSceneKey=nil;}
}
- (void)close {
    if(_closed)return;
    _closed=YES;[self hide];
    [_surface release];_surface=nil;
    [_focus release];_focus=nil;
    [_detailPoster release];_detailPoster=nil;
    [_detailPosterData release];_detailPosterData=nil;
    if(_focusColor){CGColorRelease(_focusColor);_focusColor=NULL;}
    [_tiles release];_tiles=nil;
    [_tileStamps release];_tileStamps=nil;
    [_nativeCaptions release];_nativeCaptions=nil;
    [_captionStamps release];_captionStamps=nil;
    [_captionHost release];_captionHost=nil;
    [_captionScope release];_captionScope=nil;_nativeCaptionReady=NO;
    [_lastTileScope release];_lastTileScope=nil;
    [_viewScope release];_viewScope=nil;_host=nil;
    [_sceneCache release];_sceneCache=nil;
    [_sceneOrder release];_sceneOrder=nil;
    if(_sceneQueue){dispatch_release(_sceneQueue);_sceneQueue=NULL;}
}
- (void)showScene:(NSData *)data key:(NSString *)key {
    if(_closed || !data.length || !key.length)return;
    id image=JFBRObjectWithObject(NSClassFromString(@"ATVImage"),@"imageWithData:",data);
    if(!image)return;
    JFBRCall(_surface,@"setImage:",@[image]);
    [_lastDrawKey release];_lastDrawKey=[key copy];
}
- (void)requestGridScene:(NSDictionary *)snapshot rows:(NSArray *)rows
                    key:(NSString *)key firstRow:(NSInteger)firstRow
                 search:(BOOL)search query:(NSString *)query username:(NSString *)name {
    if(_closed || !key.length)return;
    NSData *cached=_sceneCache[key];
    if(cached) {
        @synchronized(self) {
            [_pendingSceneKey release];_pendingSceneKey=[key copy];
        }
        [self showScene:cached key:key];
        return;
    }
    @synchronized(self) {
        if([_pendingSceneKey isEqualToString:key])return;
        [_pendingSceneKey release];_pendingSceneKey=[key copy];
    }
    NSDictionary *snap=[snapshot copy];
    NSArray *viewRows=[rows copy];
    NSString *requested=[key copy];
    NSString *user=[name copy],*text=[query copy];
    // This retained owner remains alive until the main-queue completion.
    JFVisualUI *owner=[self retain];
    dispatch_async(_sceneQueue,^{
        @autoreleasepool {
            BOOL current=NO;
            @synchronized(owner) {
                current=!owner->_closed &&
                        [owner->_pendingSceneKey isEqualToString:requested];
            }
            NSTimeInterval began=[NSProcessInfo processInfo].systemUptime;
            NSData *imageData=current?JFGridScene(snap,viewRows,firstRow,user,search,
                                                text,[requested hasPrefix:@"CHROME|"]):nil;
            NSInteger millis=(NSInteger)(1000*([NSProcessInfo processInfo].systemUptime-began));
            dispatch_async(dispatch_get_main_queue(),^{
                if(!owner->_closed && imageData.length) {
                    owner->_sceneCache[requested]=imageData;
                    [owner->_sceneOrder removeObject:requested];
                    [owner->_sceneOrder addObject:requested];
                    while(owner->_sceneOrder.count>8) {
                        NSString *old=[[owner->_sceneOrder objectAtIndex:0] retain];
                        [owner->_sceneOrder removeObjectAtIndex:0];
                        [owner->_sceneCache removeObjectForKey:old];
                        [old release];
                    }
                    if([owner->_pendingSceneKey isEqualToString:requested]) {
                        [owner showScene:imageData key:requested];
                        JFPosterTrace([NSString stringWithFormat:@"GRID_SCENE_READY window=%ld render_ms=%ld bytes=%lu",
                           (long)firstRow,(long)millis,(unsigned long)imageData.length]);
                    }
                }
                // Idle-time universal movie chrome: independent of library,
                // poster contents, or scroll window. Pre-render it while the
                // user is still on Libraries, so entering any movie library
                // needs ZERO per-row text-scene encodes.
                if([snap[@"page"] integerValue]==JFLibrariesPage &&
                   !owner->_sceneCache[@"CHROME|1"]) {
                    JFVisualUI *preOwner=[owner retain];
                    dispatch_async(preOwner->_sceneQueue,^{
                        @autoreleasepool {
                            NSMutableArray *placeholders=[NSMutableArray array];
                            for(NSUInteger n=0;n<10;n++)
                                [placeholders addObject:@{@"action":@"media",
                                  @"itemID":@"",@"title":@""}];
                            [placeholders addObject:@{@"action":@"back"}];
                            [placeholders addObject:@{@"action":@"search"}];
                            NSData *chrome=JFGridScene(@{@"page":@(JFMediaPage)},
                                placeholders,0,nil,NO,@"",YES);
                            dispatch_async(dispatch_get_main_queue(),^{
                                if(!preOwner->_closed && chrome.length &&
                                   !preOwner->_sceneCache[@"CHROME|1"]) {
                                    preOwner->_sceneCache[@"CHROME|1"]=chrome;
                                    [preOwner->_sceneOrder addObject:@"CHROME|1"];
                                    JFPosterTrace(@"GRID_CHROME_PREWARM_READY");
                                    if([preOwner->_pendingSceneKey isEqual:@"CHROME|1"])
                                        [preOwner showScene:chrome key:@"CHROME|1"];
                                }
                                [chrome release];[preOwner release];
                            });
                        }
                    });
                }
                [imageData release];[snap release];[viewRows release];
                [requested release];[user release];[text release];
                [owner release];
            });
        }
    });
}
- (void)idlePrebuildNeighbor:(NSDictionary *)snapshot rows:(NSArray *)rows
                           key:(NSString *)currentKey scope:(NSString *)scope
                         search:(BOOL)search query:(NSString *)query username:(NSString *)user {
    if(_closed || !_tilesReady || !currentKey || !scope ||
       [snapshot[@"page"] integerValue]==JFDetailPage)return;
    NSUInteger media=0;
    for(NSDictionary *row in rows)if([row[@"action"] isEqual:@"media"])media++;
    NSInteger page=[snapshot[@"page"] integerValue];
    NSInteger maximum=page==JFLibrariesPage?
        MAX(0,((NSInteger)[snapshot[@"libraries"] count]-1)/
                  JFLibraryColumns-(JFLibraryVisibleRows-1)):
        MAX(0,((NSInteger)media-1)/5-(search?0:1));
    NSInteger first=_visibleFirstRow,neighbor=first+1;
    if(neighbor>maximum)return;
    NSDictionary *snap=[snapshot copy];NSArray *list=[rows copy];
    NSString *origin=[currentKey copy],*sc=[scope copy],*q=[query copy],*username=[user copy];
    JFVisualUI *owner=[self retain];
    // No work at all if the user continues to press D-pad within 0.5 s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,550*NSEC_PER_MSEC),
      dispatch_get_main_queue(),^{
        if(owner->_closed || owner->_visibleFirstRow!=first ||
           ![owner->_viewScope isEqual:sc] ||
           ![owner->_pendingSceneKey isEqual:origin]) {
            [snap release];[list release];[origin release];[sc release];
            [q release];[username release];[owner release];return;
        }
        NSString *nextKey=[JFGridKey(snap,list,sc,neighbor,search,q) copy];
        if(owner->_sceneCache[nextKey]) {
            [nextKey release];[snap release];[list release];[origin release];
            [sc release];[q release];[username release];[owner release];return;
        }
        dispatch_async(owner->_sceneQueue,^{
            @autoreleasepool {
                BOOL fresh=NO;
                @synchronized(owner) {
                    fresh=!owner->_closed && [owner->_pendingSceneKey isEqual:origin];
                }
                NSData *prepared=fresh?JFGridScene(snap,list,neighbor,username,search,q,NO):nil;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(!owner->_closed && [owner->_viewScope isEqual:sc] &&
                       prepared.length && !owner->_sceneCache[nextKey]) {
                        owner->_sceneCache[nextKey]=prepared;
                        [owner->_sceneOrder removeObject:nextKey];
                        [owner->_sceneOrder addObject:nextKey];
                        while(owner->_sceneOrder.count>8) {
                            NSString *old=owner->_sceneOrder[0];
                            [owner->_sceneCache removeObjectForKey:old];
                            [owner->_sceneOrder removeObjectAtIndex:0];
                        }
                        JFPosterTrace([NSString stringWithFormat:
                            @"GRID_SCENE_IDLE_READY window=%ld",(long)neighbor]);
                    }
                    [prepared release];[nextKey release];[snap release];
                    [list release];[origin release];[sc release];
                    [q release];[username release];[owner release];
                });
            }
        });
    });
}
- (void)ensureNativeCaptions {
    if(_nativeCaptions || !_tilesReady || !_surface)return;
    if(!NSClassFromString(@"CATextLayer"))return;
    id control=JFBRNew(NSClassFromString(@"BRControl"));
    CGRect hostRect=CGRectZero;
    if(!control || !JFFrame(_host,&hostRect) || !JFSetFrame(control,hostRect) ||
       !JFBRCall(_host,@"addSubview:",@[control])) {[control release];return;}
    _captionHost=control;
    CALayer *parent=JFBRObject(control,@"layer");
    if(![parent isKindOfClass:[CALayer class]])return;
    parent.backgroundColor=NULL;
    NSMutableArray *layers=[NSMutableArray arrayWithCapacity:30];
    CGColorSpaceRef rgb=CGColorSpaceCreateDeviceRGB();
    for(NSUInteger i=0;i<30;i++) {
        CATextLayer *label=[CATextLayer layer];
        label.font=(CFTypeRef)@"STHeitiSC-Medium";
        label.fontSize=(i%2)?17.0:19.0;
        CGFloat channel=(i%2)?0.70:0.96;
        CGFloat components[]={channel,channel,channel,1};
        CGColorRef fg=CGColorCreate(rgb,components);
        label.foregroundColor=fg;CGColorRelease(fg);
        label.truncationMode=kCATruncationEnd;
        label.alignmentMode=kCAAlignmentLeft;
        label.wrapped=NO;
        label.contentsScale=1.0;
        label.hidden=YES;
        [parent addSublayer:label];
        [layers addObject:label];
    }
    CGColorSpaceRelease(rgb);
    _nativeCaptions=[layers mutableCopy];
    NSMutableArray *stamps=[NSMutableArray arrayWithCapacity:15];
    for(int n=0;n<15;n++)[stamps addObject:@""];
    _captionStamps=[stamps mutableCopy];
    _nativeCaptionReady=YES;
    _captionRow=-1;
    JFPosterTrace(@"UI_NATIVE_TEXT_CAPTIONS_READY count=30");
}
- (void)hideNativeCaptions {
    if(!_nativeCaptionReady)return;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(CALayer *layer in _nativeCaptions)layer.hidden=YES;
    [CATransaction commit];
    _captionRow=-1;
}
- (void)updateNativeCaptions:(NSArray *)rows scope:(NSString *)scope
                      search:(BOOL)search page:(NSInteger)page bounds:(CGRect)bounds {
    if(!_nativeCaptionReady || page!=JFMediaPage || search) {
        [self hideNativeCaptions];return;
    }
    if(_captionHost)JFSetFrame(_captionHost,bounds);
    NSUInteger count=0;
    for(NSDictionary *row in rows)if([row[@"action"] isEqual:@"media"])count++;
    if(_captionRow==_visibleFirstRow && _captionCount==count &&
       [_captionScope isEqualToString:scope])return;
    NSInteger prevRow=_captionRow;
    BOOL move=prevRow>=0 && [_captionScope isEqualToString:scope] &&
              ABS(prevRow-_visibleFirstRow)<=2;
    NSInteger direction=_visibleFirstRow-prevRow;
    NSArray *previous=[_nativeCaptions copy],*oldIDs=[_captionStamps copy];
    NSMutableIndexSet *assigned=[NSMutableIndexSet indexSet];
    NSMutableArray *ids=[NSMutableArray array],*permutation=[NSMutableArray array];
    NSInteger anchor=MAX(0,_visibleFirstRow-1)*5;
    for(NSUInteger slot=0;slot<15;slot++) {
        NSUInteger index=(NSUInteger)anchor+slot;
        NSString *ident=index<count && index<rows.count ?
            (rows[index][@"itemID"]?:@"") : @"";
        [ids addObject:ident];
        NSInteger matched=-1;
        if(ident.length)for(NSUInteger j=0;j<15;j++)
            if(![assigned containsIndex:j] && [oldIDs[j] isEqualToString:ident]){
                matched=(NSInteger)j;break;
            }
        [permutation addObject:@(matched)];
        if(matched>=0)[assigned addIndex:(NSUInteger)matched];
    }
    NSUInteger spare=0;
    for(NSUInteger i=0;i<15;i++)if([permutation[i] integerValue]<0){
        while(spare<15 && [assigned containsIndex:spare])spare++;
        if(spare>=15)break;
        permutation[i]=@(spare);[assigned addIndex:spare];
    }
    NSMutableArray *reordered=[NSMutableArray arrayWithCapacity:30];
    for(NSUInteger i=0;i<15;i++){
        NSUInteger j=[permutation[i] unsignedIntegerValue];
        [reordered addObject:previous[j*2]];
        [reordered addObject:previous[j*2+1]];
    }
    [_nativeCaptions setArray:reordered];
    [_captionStamps setArray:ids];
    [_captionScope release];_captionScope=[scope copy];
    _captionRow=_visibleFirstRow;_captionCount=count;
    CGFloat sx=bounds.size.width/1280.0,sy=bounds.size.height/720.0;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    for(NSUInteger slot=0;slot<15;slot++) {
        CATextLayer *name=_nativeCaptions[slot*2],*year=_nativeCaptions[slot*2+1];
        NSUInteger index=(NSUInteger)anchor+slot;
        BOOL valid=index<count && index<rows.count && [ids[slot] length];
        name.hidden=!valid;year.hidden=!valid;
        if(!valid)continue;
        NSDictionary *item=rows[index];
        CGFloat x=41+(index%5)*248;
        CGFloat y=644-((NSInteger)(index/5)-_visibleFirstRow)*310-250;
        // Inset text into the 60px inter-row corridor: both lines fit before
        // the next poster begins (previous year baseline was being clipped).
        CGRect labelRect=CGRectMake((x+1)*sx,(y-32)*sy,223*sx,23*sy);
        CGRect yearRect=CGRectMake((x+1)*sx,(y-58)*sy,170*sx,23*sy);
        CGPoint oldName=((CALayer *)[name presentationLayer]?:name).position;
        CGPoint oldYear=((CALayer *)[year presentationLayer]?:year).position;
        BOOL same=[oldIDs[[permutation[slot] unsignedIntegerValue]]
                      isEqualToString:ids[slot]];
        name.string=JFClip(item[@"name"]?:item[@"title"],14);
        NSString *value=[item[@"year"] description];
        year.string=(value.length && ![value isEqual:@"0"])?value:@"";
        name.frame=labelRect;year.frame=yearRect;
        name.fontSize=19*sy;year.fontSize=17*sy;
        // One previous/next row stays pre-positioned outside the viewport.
        // Fade it away rather than letting captions overlap the top buttons.
        BOOL onScreen=(index/5>=(NSUInteger)_visibleFirstRow &&
                       index/5<(NSUInteger)(_visibleFirstRow+2));
        name.opacity=onScreen?1.0:0.0;year.opacity=onScreen?1.0:0.0;
        if(move && direction && !CGRectIsEmpty(labelRect)){
            for(CATextLayer *layer in @[name,year]) {
                CGPoint to=layer.position;
                CGPoint from=(layer==name)?oldName:oldYear;
                if(!same || fabs(to.y-from.y)>800*sy)
                    from=CGPointMake(to.x,to.y-(direction>0?310:-310)*sy);
                CABasicAnimation *slide=[CABasicAnimation animationWithKeyPath:@"position"];
                slide.fromValue=[NSValue valueWithBytes:&from objCType:@encode(CGPoint)];
                slide.toValue=[NSValue valueWithBytes:&to objCType:@encode(CGPoint)];
                slide.duration=0.24;
                slide.beginTime=_sharedScrollStart;
                slide.fillMode=kCAFillModeBackwards;
                slide.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [layer removeAnimationForKey:@"JFRowScroll"];
                [layer addAnimation:slide forKey:@"JFRowScroll"];
                CABasicAnimation *alpha=[CABasicAnimation animationWithKeyPath:@"opacity"];
                alpha.fromValue=@(onScreen?(same?1:0):1);
                alpha.toValue=@(onScreen?1:0);
                alpha.duration=0.24;
                alpha.beginTime=_sharedScrollStart;
                alpha.fillMode=kCAFillModeBackwards;
                [layer removeAnimationForKey:@"JFRowFade"];
                [layer addAnimation:alpha forKey:@"JFRowFade"];
            }
        }
    }
    [CATransaction commit];
    [previous release];[oldIDs release];
}
- (void)updateDetailPoster:(NSDictionary *)snapshot artwork:(JFArtwork *)art
                         fallback:(NSData *)fallback bounds:(CGRect)bounds {
    if(!_detailPoster)return;
    NSString *identifier=snapshot[@"detail"][@"Id"];
    NSData *bytes=[art imageBytesForID:identifier type:@"Primary" width:400];
    if(!bytes.length && [fallback isKindOfClass:[NSData class]])bytes=fallback;
    if(!bytes.length) {
        [_detailPosterData release];_detailPosterData=nil;
        JFBRCall(_detailPoster,@"setImage:",@[[NSNull null]]);
        JFSetFrame(_detailPoster,CGRectZero);return;
    }
    CGRect logical=CGRectMake(43,24,324,466);
    CGRect scaled=CGRectMake(bounds.origin.x+logical.origin.x*bounds.size.width/1280.,
        bounds.origin.y+logical.origin.y*bounds.size.height/720.,
        logical.size.width*bounds.size.width/1280.,
        logical.size.height*bounds.size.height/720.);
    BOOL changed=![_detailPosterData isEqualToData:bytes];
    if(changed) {
        id image=JFBRObjectWithObject(NSClassFromString(@"ATVImage"),@"imageWithData:",bytes);
        if(!image)return;
        JFBRCall(_detailPoster,@"setImage:",@[image]);
        [_detailPosterData release];_detailPosterData=[bytes copy];
    }
    JFSetFrame(_detailPoster,scaled);
    if(changed) {
        CALayer *layer=JFBRObject(_detailPoster,@"layer");
        if([layer isKindOfClass:[CALayer class]]) {
            [layer removeAnimationForKey:@"JFPosterAppear"];
            CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
            fade.fromValue=@0.0;fade.toValue=@1.0;
            fade.duration=0.22;
            fade.timingFunction=[CAMediaTimingFunction
                functionWithName:kCAMediaTimingFunctionEaseOut];
            [layer addAnimation:fade forKey:@"JFPosterAppear"];
        }
    }
}
- (void)updateNativeTiles:(NSDictionary *)snapshot rows:(NSArray *)rows
                     artwork:(JFArtwork *)art page:(NSInteger)page
                      search:(BOOL)search bounds:(CGRect)bounds {
    if(!_tilesReady)return;
    NSInteger start=(search&&page==JFMediaPage)?1:0;
    NSInteger count=0;
    for(NSDictionary *row in rows)
        if([row[@"action"] isEqual:@"media"])count++;
    if(page==JFLibrariesPage)count=(NSInteger)[snapshot[@"libraries"] count];
    NSInteger span=page==JFLibrariesPage?JFLibraryColumns:5;
    NSInteger maxVisible=page==JFLibrariesPage?JFLibraryVisibleRows:(search?1:2);
    BOOL animatedMedia=page==JFMediaPage && !search;
    NSInteger first=(animatedMedia?MAX(0,_visibleFirstRow-1):_visibleFirstRow)*span;
    NSInteger allowed=animatedMedia?15:maxVisible*span;
    BOOL scrolling=animatedMedia && _lastTileRow!=_visibleFirstRow &&
        _lastTilePage==page && [_lastTileScope isEqualToString:_viewScope] &&
        ABS(_lastTileRow-_visibleFirstRow)<=2;
    NSInteger scrollDelta=_visibleFirstRow-_lastTileRow;
    // Match existing native poster layers by MEDIA ID before assigning new
    // positions. When a five-column row scrolls, five existing controls move
    // up; only the five newly entering posters need setImage/decode work.
    NSUInteger tileCount=_tiles.count;
    NSMutableArray *wanted=[NSMutableArray arrayWithCapacity:tileCount];
    for(NSUInteger slot=0;slot<tileCount;slot++) {
        NSInteger index=first+(NSInteger)slot;
        NSString *identifier=@"",*kind=@"Primary";
        if(index<count && (NSInteger)slot<allowed) {
            if(page==JFLibrariesPage) {
                NSDictionary *item=snapshot[@"libraries"][(NSUInteger)index];
                identifier=item[@"Id"]?:@"";
                NSDictionary *tags=item[@"ImageTags"];
                if(!tags[@"Primary"] && tags[@"Thumb"])kind=@"Thumb";
            } else if(page!=JFDetailPage) {
                identifier=rows[(NSUInteger)(index+start)][@"itemID"]?:@"";
            }
        }
        [wanted addObject:identifier.length?[NSString stringWithFormat:@"%@/%@/",identifier,kind]:@""];
    }
    NSMutableIndexSet *assigned=[NSMutableIndexSet indexSet];
    NSMutableArray *permutation=[NSMutableArray arrayWithCapacity:tileCount];
    for(NSUInteger slot=0;slot<tileCount;slot++) [permutation addObject:@(-1)];
    for(NSUInteger slot=0;slot<tileCount;slot++) {
        NSString *prefix=wanted[slot];if(!prefix.length)continue;
        for(NSUInteger old=0;old<tileCount;old++) {
            if([assigned containsIndex:old])continue;
            if([_tileStamps[old] hasPrefix:prefix]) {
                permutation[slot]=@(old);[assigned addIndex:old];break;
            }
        }
    }
    NSUInteger spare=0;
    for(NSUInteger slot=0;slot<tileCount;slot++) {
        if([permutation[slot] integerValue]>=0)continue;
        while(spare<tileCount && [assigned containsIndex:spare])spare++;
        if(spare>=tileCount)break;
        permutation[slot]=@(spare);
        [assigned addIndex:spare];
    }
    NSArray *previousTiles=[_tiles copy],*previousStamps=[_tileStamps copy];
    for(NSUInteger slot=0;slot<tileCount;slot++) {
        NSUInteger idx=[permutation[slot] unsignedIntegerValue];
        _tiles[slot]=previousTiles[idx];
        _tileStamps[slot]=previousStamps[idx];
    }
    [previousTiles release];
    NSUInteger changedImages=0;BOOL deferredImages=NO;
    for(NSInteger i=0;i<(NSInteger)_tiles.count;i++) {
        id tile=_tiles[(NSUInteger)i];
        NSString *identifier=nil,*type=@"Primary";
        CGRect frame=CGRectZero;
        NSInteger index=first+i;
        if(i<allowed && index<count) {
            if(page==JFLibrariesPage) {
                NSDictionary *item=snapshot[@"libraries"][(NSUInteger)index];
                identifier=item[@"Id"];
                NSDictionary *tags=item[@"ImageTags"];
                if(!tags[@"Primary"] && tags[@"Thumb"])type=@"Thumb";
                frame=JFLibraryCardRect(index,_visibleFirstRow);
            }else if(page!=JFDetailPage) {
                NSDictionary *row=rows[(NSUInteger)(index+start)];
                identifier=row[@"itemID"];
                CGFloat x=41+(index%5)*248;
                CGFloat y=(search?485:644)-(index/5-_visibleFirstRow)*(search?320:310)-250;
                frame=CGRectMake(x,y,201,250);
            }
        }
        if(!identifier.length) {
            if(![_tileStamps[(NSUInteger)i] isEqual:@""]) {
                JFBRCall(tile,@"setImage:",@[[NSNull null]]);
                _tileStamps[(NSUInteger)i]=@"";
            }
            CALayer *unused=JFBRObject(tile,@"layer");
            if([unused isKindOfClass:[CALayer class]]) {
                [unused removeAnimationForKey:@"JFGridRowPosition"];
                [unused removeAnimationForKey:@"JFGridRowVisibility"];
                [unused removeAnimationForKey:@"JFPosterAppear"];
                unused.opacity=0;
            }
            JFSetFrame(tile,CGRectZero);continue;
        }
        CALayer *layer=JFBRObject(tile,@"layer");
        CGPoint original=CGPointZero;
        BOOL sameID=[previousStamps[[permutation[(NSUInteger)i] unsignedIntegerValue]]
            hasPrefix:[NSString stringWithFormat:@"%@/%@/",identifier,type]];
        if([layer isKindOfClass:[CALayer class]]) {
            original=((CALayer *)[layer presentationLayer]?:layer).position;
            layer.masksToBounds=YES;
            layer.cornerRadius=page==JFLibrariesPage?10.0:0.0;
            layer.contentsGravity=kCAGravityResizeAspectFill;
        }
        NSData *data=[art imageBytesForID:identifier type:type width:400];
        NSString *stamp=[NSString stringWithFormat:@"%@/%@/%d",identifier,type,data!=nil];
        if(![_tileStamps[(NSUInteger)i] isEqual:stamp]) {
            // Reused BackRow tile may still show ANOTHER movie. Clear the old
            // pixels before postponing a costly imageWithData conversion.
            BOOL reused= ![_tileStamps[(NSUInteger)i] hasPrefix:
                [NSString stringWithFormat:@"%@/%@/",identifier,type]];
            if(reused) {
                JFBRCall(tile,@"setImage:",@[[NSNull null]]);
                _tileStamps[(NSUInteger)i]=@"";
            }
            if(data && changedImages>=2)deferredImages=YES;
            else {
                id image=data?JFBRObjectWithObject(NSClassFromString(@"ATVImage"),@"imageWithData:",data):nil;
                JFBRCall(tile,@"setImage:",@[image?:[NSNull null]]);
                _tileStamps[(NSUInteger)i]=stamp;
                if(data && image) {
                    changedImages++;
                    // Fade in ONLY when pixels arrive or this tile first
                    // adopts a new movie. No timer and no full-frame redraw.
                    CALayer *posterLayer=JFBRObject(tile,@"layer");
                    if([posterLayer isKindOfClass:[CALayer class]]) {
                        [posterLayer removeAnimationForKey:@"JFPosterAppear"];
                        CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
                        fade.fromValue=@0.0;fade.toValue=@1.0;
                        fade.duration=0.22;
                        fade.timingFunction=[CAMediaTimingFunction
                            functionWithName:kCAMediaTimingFunctionEaseOut];
                        [posterLayer addAnimation:fade forKey:@"JFPosterAppear"];
                    }
                }
            }
        }
        CGRect view=CGRectMake(bounds.origin.x+frame.origin.x*bounds.size.width/1280.,
            bounds.origin.y+frame.origin.y*bounds.size.height/720.,
            frame.size.width*bounds.size.width/1280.,
            frame.size.height*bounds.size.height/720.);
        // A moving row reuses real BRImageControl layers. New posters enter
        // from the viewport boundary; no frame-by-frame JPEG encoding.
        BOOL active=(!animatedMedia || (index/5>=_visibleFirstRow &&
                      index/5<_visibleFirstRow+2));
        if([layer isKindOfClass:[CALayer class]]) {
            [CATransaction begin];[CATransaction setDisableActions:YES];
            JFSetFrame(tile,view);
            CGPoint target=layer.position;
            CGFloat targetOpacity=active?1.f:0.f;
            layer.opacity=targetOpacity;
            if(scrolling) {
                CGPoint from=original;
                if(!sameID || !isfinite(from.y) ||
                   fabs(from.y-target.y)>800*bounds.size.height/720.)
                    from=CGPointMake(target.x,target.y-
                      (scrollDelta>0?310:-310)*bounds.size.height/720.);
                CABasicAnimation *shift=[CABasicAnimation animationWithKeyPath:@"position"];
                shift.fromValue=[NSValue valueWithBytes:&from objCType:@encode(CGPoint)];
                shift.toValue=[NSValue valueWithBytes:&target objCType:@encode(CGPoint)];
                shift.duration=0.24;
                shift.beginTime=_sharedScrollStart;
                shift.fillMode=kCAFillModeBackwards;
                shift.timingFunction=[CAMediaTimingFunction functionWithName:
                                        kCAMediaTimingFunctionEaseInEaseOut];
                [layer removeAnimationForKey:@"JFGridRowPosition"];
                [layer addAnimation:shift forKey:@"JFGridRowPosition"];
                CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
                fade.fromValue=@(active?(sameID?1:0):1);
                fade.toValue=@(targetOpacity);
                fade.duration=0.24;
                fade.beginTime=_sharedScrollStart;
                fade.fillMode=kCAFillModeBackwards;
                [layer removeAnimationForKey:@"JFPosterAppear"];
                [layer removeAnimationForKey:@"JFGridRowVisibility"];
                [layer addAnimation:fade forKey:@"JFGridRowVisibility"];
            }
            [CATransaction commit];
        } else JFSetFrame(tile,view);
    }
    [previousStamps release];
    if(deferredImages && !_closed) {
        NSDictionary *snap=[snapshot retain];NSArray *captured=[rows retain];
        JFArtwork *artwork=[art retain];NSString *scope=[_viewScope copy];
        NSInteger visible=_visibleFirstRow;JFVisualUI *owner=[self retain];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if(!owner->_closed && owner->_visibleFirstRow==visible && [owner->_viewScope isEqual:scope])
                [owner updateNativeTiles:snap rows:captured artwork:artwork page:page search:search bounds:bounds];
            [snap release];[captured release];[artwork release];[scope release];[owner release];
        });
    }
    // Background prefetch of the next and previous row: no JPEG encoding, no
    // imageWithData: on the D-pad path; only enqueue eventual worker loads.
    if(page!=JFLibrariesPage && page!=JFDetailPage) {
        for(NSInteger delta=-1;delta<=maxVisible;delta++) {
            if(delta>=0 && delta<maxVisible)continue;
            NSInteger row=_visibleFirstRow+delta;
            if(row<0)continue;
            for(NSInteger col=0;col<5;col++) {
                NSInteger idx=row*5+col;
                if(idx<0 || idx>=count)continue;
                NSDictionary *item=rows[(NSUInteger)(idx+start)];
                CGImageRef image=[art copyImageForID:item[@"itemID"] type:@"Primary" width:400];
                if(image)CGImageRelease(image);
            }
        }
    }
}
- (void)moveFocusTo:(CGRect)logical bounds:(CGRect)bounds animated:(BOOL)animated {
    if(!_focus)return;
    if(CGRectIsEmpty(logical) || !bounds.size.width || !bounds.size.height) {
        _focusFrame=CGRectZero;
        JFSetFrame(_focus,CGRectZero);return;
    }
    CGRect frame=CGRectMake(bounds.origin.x+logical.origin.x*bounds.size.width/1280.,
                           bounds.origin.y+logical.origin.y*bounds.size.height/720.,
                           logical.size.width*bounds.size.width/1280.,
                           logical.size.height*bounds.size.height/720.);
    if(CGRectEqualToRect(frame,_focusFrame))return;
    CGRect old=_focusFrame;
    _focusFrame=frame;
    // The BackRow BRControl owns a real CALayer. Move a single thin outline
    // through CoreAnimation rather than encoding a JPEG for each keypress.
    JFSetFrame(_focus,frame);
    if(animated && !CGRectIsEmpty(old) && JFBRHas(_focus,@"addAnimation:forKey:",@encode(void),@[@"@",@"@"])) {
        CABasicAnimation *animation=[CABasicAnimation animationWithKeyPath:@"position"];
        CGPoint start=CGPointMake(CGRectGetMidX(old),CGRectGetMidY(old));
        CGPoint finish=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
        animation.fromValue=[NSValue valueWithBytes:&start objCType:@encode(CGPoint)];
        animation.toValue=[NSValue valueWithBytes:&finish objCType:@encode(CGPoint)];
        animation.duration=0.105;
        animation.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        JFBRCall(_focus,@"addAnimation:forKey:",@[animation,@"JellyfinFocusSlide"]);
    }
}
- (void)renderSnapshot:(NSDictionary *)snapshot rows:(NSArray *)rows selection:(long)selection
               artwork:(JFArtwork *)artwork poster:(NSData *)poster username:(NSString *)username
                search:(BOOL)search query:(NSString *)query scroll:(CGFloat)scroll {
    if(_closed||!_host||![NSThread isMainThread])return;
    NSInteger page=[snapshot[@"page"] integerValue];
    if(page==JFLoginPage || page==JFLibraryPage){[self hide];return;}
    if(!_surface) {
        id surface=JFBRNew(NSClassFromString(@"BRImageControl"));
        CGRect bounds=CGRectZero;
        if(!surface||!JFFrame(_host,&bounds)||!JFSetFrame(surface,bounds)||
           !JFBRHas(_host,@"addSubview:",@encode(void),@[@"@"])||
           !JFBRHas(surface,@"setImage:",@encode(void),@[@"@"])) {[surface release];return;}
        JFBRCall(_host,@"addSubview:",@[surface]);_surface=surface;
    }
    CGRect bounds=CGRectZero;if(!JFFrame(_host,&bounds))return;JFSetFrame(_surface,bounds);
    if(!_tiles && (page==JFLibrariesPage || page==JFMediaPage ||
                    page==JFSeasonsPage || page==JFEpisodesPage)) {
        NSMutableArray *views=[NSMutableArray array],*stamps=[NSMutableArray array];
        BOOL valid=YES;
        for(NSInteger i=0;i<15;i++) {
            id tile=JFBRNew(NSClassFromString(@"BRImageControl"));
            if(!tile || !JFBRHas(tile,@"setImage:",@encode(void),@[@"@"]) ||
               !JFSetFrame(tile,CGRectZero) ||
               !JFBRCall(_host,@"addSubview:",@[tile]))valid=NO;
            if(tile){[views addObject:tile];[tile release];}
            [stamps addObject:@""];
            if(!valid)break;
        }
        if(valid && views.count==15) {
            _tiles=[views mutableCopy];_tileStamps=[stamps mutableCopy];_tilesReady=YES;
            JFPosterTrace(@"UI_NATIVE_TILE_LAYERS_READY count=15");
        }
    }
    if(!_focus) {
        id ctrl=JFBRNew(NSClassFromString(@"BRControl"));
        if(ctrl && JFBRHas(_host,@"addSubview:",@encode(void),@[@"@"]) &&
           [ctrl respondsToSelector:NSSelectorFromString(@"setBorderColor:")]) {
            CGColorSpaceRef rgb=CGColorSpaceCreateDeviceRGB();
            CGFloat channels[]={0.08,0.75,0.96,1.0};
            _focusColor=CGColorCreate(rgb,channels);CGColorSpaceRelease(rgb);
            ((void(*)(id,SEL,CGColorRef))objc_msgSend)(ctrl,NSSelectorFromString(@"setBorderColor:"),_focusColor);
            JFSetFloat(ctrl,@"setBorderWidth:",4.0f);
            CALayer *focusLayer=JFBRObject(ctrl,@"layer");
            if([focusLayer isKindOfClass:[CALayer class]]) {
                focusLayer.cornerRadius=20.0;
                focusLayer.masksToBounds=YES;
                focusLayer.backgroundColor=NULL; // hollow cyan border only
                focusLayer.borderColor=_focusColor;
                focusLayer.borderWidth=4.0;
            }
            JFBRCall(_host,@"addSubview:",@[ctrl]);_focus=ctrl;
            JFPosterTrace(@"UI_NATIVE_FOCUS_LAYER_READY");
        } else [ctrl release];
    }
    if(page==JFDetailPage) {
        if(!_detailPoster) {
            id pic=JFBRNew(NSClassFromString(@"BRImageControl"));
            if(pic && JFBRHas(pic,@"setImage:",@encode(void),@[@"@"]) &&
               JFSetFrame(pic,CGRectZero) &&
               JFBRCall(_host,@"addSubview:",@[pic])) {
                _detailPoster=pic;
                CALayer *l=JFBRObject(pic,@"layer");
                if([l isKindOfClass:[CALayer class]]) {
                    l.masksToBounds=YES;
                    l.cornerRadius=4.0;
                    l.contentsGravity=kCAGravityResizeAspectFill;
                }
            }else [pic release];
        }
        [self updateDetailPoster:snapshot artwork:artwork fallback:poster bounds:bounds];
    } else if(_detailPoster) {
        JFSetFrame(_detailPoster,CGRectZero);
        [_detailPosterData release];_detailPosterData=nil;
    }
    if(_focus && _loginFocusTransition && page==JFLibrariesPage &&
       !_focusRevealScheduled) {
        _focusRevealScheduled=YES;
        CALayer *focusLayer=JFBRObject(_focus,@"layer");
        if([focusLayer isKindOfClass:[CALayer class]]) focusLayer.opacity=0;
        JFVisualUI *owner=[self retain];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if(!owner->_closed && owner->_focusRevealScheduled &&
               [owner->_viewScope hasPrefix:@"1|"]) {
                CALayer *l=JFBRObject(owner->_focus,@"layer");
                if([l isKindOfClass:[CALayer class]]) {
                    [l removeAnimationForKey:@"JFInitialFocus"];
                    l.opacity=1;
                    CABasicAnimation *appear=[CABasicAnimation animationWithKeyPath:@"opacity"];
                    appear.fromValue=@0;appear.toValue=@1;
                    appear.duration=0.14;
                    [l addAnimation:appear forKey:@"JFInitialFocus"];
                }
                owner->_loginFocusTransition=NO;
            }
            owner->_focusRevealScheduled=NO;
            [owner release];
        });
    }
    NSArray *libraries=[snapshot[@"libraries"] isKindOfClass:[NSArray class]]?snapshot[@"libraries"]:@[];
    NSInteger currentLib=[snapshot[@"index"] integerValue];
    NSDictionary *lib=(currentLib>=0 && (NSUInteger)currentLib<libraries.count)?libraries[(NSUInteger)currentLib]:nil;
    NSString *libID=page==JFLibrariesPage?@"all":(lib[@"Id"]?:@"none");
    NSString *scope=[NSString stringWithFormat:@"%ld|%@|%@|%d",(long)page,
                      libID,snapshot[@"detail"][@"Id"]?:@"",search];
    if(![_viewScope isEqual:scope]){
        if(page!=JFLibrariesPage && _focus) {
            CALayer *focus=JFBRObject(_focus,@"layer");
            if([focus isKindOfClass:[CALayer class]])focus.opacity=1;
            _loginFocusTransition=NO;
        }
        _captionRow=-1;
        [_viewScope release];_viewScope=[scope copy];_visibleFirstRow=0;
        [_lastTileScope release];_lastTileScope=nil;
        @synchronized(self) {[_pendingSceneKey release];_pendingSceneKey=nil;}
        [_lastDrawKey release];_lastDrawKey=nil;
    }
    NSInteger start=search&&page==JFMediaPage?1:0;
    NSInteger mediaCount=0;
    for(NSDictionary *row in rows)if([row[@"action"] isEqual:@"media"])mediaCount++;
    if(page==JFLibrariesPage){
        NSInteger maxRow=MAX(0,((NSInteger)[snapshot[@"libraries"] count]-1)/
                      JFLibraryColumns-(JFLibraryVisibleRows-1));
        if(selection>=0 && selection<(NSInteger)[snapshot[@"libraries"] count]) {
            NSInteger focused=selection/JFLibraryColumns;
            if(focused<_visibleFirstRow)_visibleFirstRow=focused;
            if(focused>=_visibleFirstRow+JFLibraryVisibleRows)
                _visibleFirstRow=focused-(JFLibraryVisibleRows-1);
        }
        _visibleFirstRow=MAX(0,MIN(_visibleFirstRow,maxRow));
    }else if(page!=JFDetailPage) {
        NSInteger maxRow=MAX(0,(mediaCount-1)/5-(search?0:1));
        if(selection>=start && selection<start+mediaCount) {
            NSInteger focused=(selection-start)/5;
            if(focused<_visibleFirstRow)_visibleFirstRow=focused;
            if(focused>=_visibleFirstRow+(search?1:2))
                _visibleFirstRow=focused-(search?0:1);
        }
        _visibleFirstRow=MAX(0,MIN(_visibleFirstRow,maxRow));
    }
    if(page!=JFDetailPage && page!=JFLibrariesPage && selection>=0 &&
       (NSUInteger)selection<rows.count &&
       [rows[(NSUInteger)selection][@"action"] isEqual:@"media"]) {
        CGImageRef focusPoster=[artwork copyImageForID:rows[(NSUInteger)selection][@"itemID"]
                                                  type:@"Primary" width:400];
        if(focusPoster)CGImageRelease(focusPoster);
    }
    CGRect focus=JFFocusRect(page,rows,snapshot,selection,_visibleFirstRow,search,scroll);
    // Build caption overlay while idle on Libraries, not on the Select path.
    if((page==JFLibrariesPage || page==JFMediaPage) && !search)
        [self ensureNativeCaptions];
    NSUInteger artVersion=artwork.artworkVersion;
    BOOL startRowMotion=(page==JFMediaPage && !search &&
        _lastTileRow!=_visibleFirstRow && _lastTilePage==page &&
        [_lastTileScope isEqualToString:scope] &&
        ABS(_lastTileRow-_visibleFirstRow)<=2);
    _sharedScrollStart=startRowMotion?(CACurrentMediaTime()+0.045):0;
    // A single outer CA transaction commits both poster and caption movement
    // in the same render frame. Previously captions animated before image setup.
    [CATransaction begin];
    BOOL tileDirty=_tilesReady &&
        (![_lastTileScope isEqualToString:scope] ||
         _lastTileRow!=_visibleFirstRow || _lastTilePage!=page ||
         _lastTileArtworkVersion!=artVersion || _lastTileCount!=rows.count ||
         _lastTileSearch!=search);
    if(tileDirty || !_tilesReady) {
        [self updateNativeTiles:snapshot rows:rows artwork:artwork
                          page:page search:search bounds:bounds];
        [_lastTileScope release];_lastTileScope=[scope copy];
        _lastTileRow=_visibleFirstRow;_lastTilePage=page;
        _lastTileArtworkVersion=artVersion;_lastTileCount=rows.count;
        _lastTileSearch=search;
    }
    [self updateNativeCaptions:rows scope:scope search:search page:page bounds:bounds];
    [CATransaction commit];
    // Ordinary D-pad movement only updates the focus CALayer.
    // Selection itself is never part of the expensive scene identity.
    NSMutableString *visibleLabels=[NSMutableString string];
    if(page==JFDetailPage) {
        for(NSDictionary *r in rows)[visibleLabels appendFormat:@"%@,",r[@"title"]?:@""];
    } else if(page==JFLibrariesPage) {
        NSArray *all=snapshot[@"libraries"];
        for(NSInteger i=_visibleFirstRow*JFLibraryColumns;i<(NSInteger)all.count &&
            i<(_visibleFirstRow+JFLibraryVisibleRows)*JFLibraryColumns;i++)
            [visibleLabels appendFormat:@"%@,",all[(NSUInteger)i][@"Name"]?:@""];
    } else {
        NSInteger first=_visibleFirstRow*5;
        NSInteger limit=MIN(mediaCount,first+(search?5:10));
        for(NSInteger i=first;i<limit;i++) {
            NSInteger idx=i+(search?1:0);
            NSDictionary *r=rows[(NSUInteger)idx];
            [visibleLabels appendFormat:@"%@:%@,",r[@"name"]?:r[@"title"]?:@"",r[@"year"]?:@""];
        }
    }
    NSString *renderKey=[NSString stringWithFormat:@"%@|%ld|%lu|%ld|%@|%@|%@|%ld|%ld",
       scope,(long)_visibleFirstRow,(unsigned long)(_tilesReady && page!=JFDetailPage?0:artwork.artworkVersion),
       (long)mediaCount,rows.count?rows[0][@"title"]:@"",
       query?:@"",visibleLabels,(long)(scroll*2),(long)poster.length];
    if(!_focus)renderKey=[renderKey stringByAppendingFormat:@"|focus=%ld",(long)selection];
    [self moveFocusTo:focus bounds:bounds animated:!CGRectIsEmpty(_focusFrame)];
    if(page==JFMediaPage && !search && _nativeCaptionReady && _tilesReady && _focus)
        renderKey=[NSString stringWithFormat:@"CHROME|%d",(mediaCount>0)];
    else if(page!=JFDetailPage && _tilesReady && _focus)
        renderKey=JFGridKey(snapshot,rows,scope,_visibleFirstRow,search,query);
    if([_lastDrawKey isEqual:renderKey])return;
    if(page!=JFDetailPage && _tilesReady && _focus) {
        [self requestGridScene:snapshot rows:rows key:renderKey
                      firstRow:_visibleFirstRow search:search
                         query:query username:username];
        if(![renderKey hasPrefix:@"CHROME|"])
            [self idlePrebuildNeighbor:snapshot rows:rows key:renderKey scope:scope
                                search:search query:query username:username];
        return;
    }
    [_lastDrawKey release];_lastDrawKey=[renderKey copy];
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    // Grid screenshots use a smaller raster to improve A5 response time;
    // detail text and imagery remain full 720p.
    size_t width=page==JFDetailPage?1280:1024;
    size_t height=page==JFDetailPage?720:576;
    CGContextRef c=CGBitmapContextCreate(NULL,width,height,8,width*4,space,
                kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);if(!c)return;
    CGContextScaleCTM(c,(CGFloat)width/1280.0,(CGFloat)height/720.0);
    JFFill(c,0.055,0.055,0.059,1,CGRectMake(0,0,1280,720));
    long nativeSelection=_focus?-1:selection;
    if(page==JFLibrariesPage)JFDrawLibrary(c,snapshot,rows,nativeSelection,_visibleFirstRow,artwork,username,_tilesReady);
    else if(page==JFDetailPage)JFDrawDetail(c,snapshot,rows,nativeSelection,artwork,poster,scroll,_detailPoster!=nil);
    else JFDrawMedia(c,snapshot,rows,nativeSelection,_visibleFirstRow,artwork,username,
                      search,query,_tilesReady,NO);
    CGImageRef pixels=CGBitmapContextCreateImage(c);CGContextRelease(c);if(!pixels)return;
    NSMutableData *out=[NSMutableData data];
    CGImageDestinationRef dest=CGImageDestinationCreateWithData((CFMutableDataRef)out,CFSTR("public.jpeg"),1,NULL);
    if(dest){CGImageDestinationAddImage(dest,pixels,(CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality:@0.79});
        CGImageDestinationFinalize(dest);CFRelease(dest);}
    CGImageRelease(pixels);
    id image=JFBRObjectWithObject(NSClassFromString(@"ATVImage"),@"imageWithData:",out);
    if(image)JFBRCall(_surface,@"setImage:",@[image]);
    [self moveFocusTo:focus bounds:bounds animated:!CGRectIsEmpty(_focusFrame)];
}
- (void)dealloc {[self close];[super dealloc];}
@end
