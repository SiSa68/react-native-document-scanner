
#import "RNPdfScannerManager.h"
#import "DocumentScannerView.h"

#import <React/RCTBridge.h>
#import <React/RCTUIManager.h>
#import <React/RCTLog.h>

@interface RNPdfScannerManager()
@property (strong, nonatomic) DocumentScannerView *scannerView;
@end

@implementation RNPdfScannerManager

// - (dispatch_queue_t)methodQueue
// {
//     return dispatch_get_main_queue();
// }

RCT_EXPORT_MODULE()

RCT_EXPORT_VIEW_PROPERTY(onScanTaken, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onRectangleDetect, RCTDirectEventBlock)

RCT_EXPORT_VIEW_PROPERTY(overlayColor, UIColor)
RCT_EXPORT_VIEW_PROPERTY(enableTorch, BOOL)
RCT_EXPORT_VIEW_PROPERTY(useFrontCam, BOOL)
RCT_EXPORT_VIEW_PROPERTY(useBase64, BOOL)
RCT_EXPORT_VIEW_PROPERTY(saveInAppDocument, BOOL)
RCT_EXPORT_VIEW_PROPERTY(captureMultiple, BOOL)
RCT_EXPORT_VIEW_PROPERTY(detectionCountBeforeCapture, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(durationBetweenCaptures, double)
RCT_EXPORT_VIEW_PROPERTY(detectionRefreshRateInMS, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(saturation, float)
RCT_EXPORT_VIEW_PROPERTY(quality, float)
RCT_EXPORT_VIEW_PROPERTY(brightness, float)
RCT_EXPORT_VIEW_PROPERTY(contrast, float)

RCT_EXPORT_METHOD(start) {
  [_scannerView start];
}

RCT_EXPORT_METHOD(stop) {
  [_scannerView stop];
}

RCT_EXPORT_METHOD(processPickedImage:(NSString *)path callback:(RCTResponseSenderBlock)callback) {

    // NSLog(@"image path: %@", path);

    NSURL *localurl = [NSURL URLWithString:path];
    UIImage *img = [UIImage imageWithContentsOfFile:localurl.path];
    // NSData *data = [NSData dataWithContentsOfURL:localurl];
    // UIImage *img = [[UIImage alloc] initWithData:data];
    [_scannerView detectImageRect:img callback:callback];
}

// RCT_EXPORT_METHOD(capture:(nonnull NSNumber *)reactTag) {

//     [_scannerView capture];
// }

// - (UIView*) view {
//     _scannerView = [[DocumentScannerView alloc] init];
//     return _scannerView;
// }

RCT_EXPORT_METHOD(capture:(nonnull NSNumber *)reactTag)
{
    [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, DocumentScannerView *> *viewRegistry) {
        DocumentScannerView *view = viewRegistry[reactTag];
        if (![view isKindOfClass:[DocumentScannerView class]]) {
            RCTLogError(@"Invalid view returned from registry, expecting DocumentScannerView, got: %@", view);
        } else {
            [view capture];
        }
    }];
}

- (UIView*) view {
    _scannerView = [DocumentScannerView new];
    return _scannerView;
    // return [DocumentScannerView new];
}

@end
