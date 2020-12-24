//
//  IPDFCameraViewController.m
//  InstaPDF
//
//  Created by Maximilian Mackh on 06/01/15.
//  Copyright (c) 2015 mackh ag. All rights reserved.
//

#import "IPDFCameraViewController.h"

#import <React/RCTInvalidating.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <GLKit/GLKit.h>

@interface IPDFCameraViewController () <AVCaptureVideoDataOutputSampleBufferDelegate, RCTInvalidating>

@property (nonatomic,strong) AVCaptureSession *captureSession;
@property (nonatomic,strong) AVCaptureDevice *captureDevice;
@property (nonatomic,strong) EAGLContext *context;

@property (nonatomic, strong) AVCaptureStillImageOutput* stillImageOutput;

@property (nonatomic, assign) BOOL forceStop;
@property (nonatomic, assign) float lastDetectionRate;

@property (atomic, assign) BOOL isCapturing;
@property (atomic, assign) CGFloat imageDetectionConfidence;

@end

@implementation IPDFCameraViewController
{
    CIContext *_coreImageContext;
    GLuint _renderBuffer;
    GLKView *_glkView;

    BOOL _isStopped;

    NSTimer *_borderDetectTimeKeeper;
    BOOL _borderDetectFrame;
    CIRectangleFeature *_borderDetectLastRectangleFeature;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backgroundMode) name:UIApplicationWillResignActiveNotification object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_foregroundMode) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)_backgroundMode
{
    self.forceStop = YES;
}

- (void)_foregroundMode
{
    self.forceStop = NO;
}

- (void)invalidate
{
  [self stop];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)createGLKView
{
    if (self.context) return;

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    GLKView *view = [[GLKView alloc] initWithFrame:self.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.translatesAutoresizingMaskIntoConstraints = YES;
    view.context = self.context;
    view.contentScaleFactor = 1.0f;
    view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
    [self insertSubview:view atIndex:0];
    _glkView = view;
    glGenRenderbuffers(1, &_renderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderBuffer);
    _coreImageContext = [CIContext contextWithEAGLContext:self.context];
    [EAGLContext setCurrentContext:self.context];
}

- (void)setupCameraView
{
    [self createGLKView];

    AVCaptureDevice *device = nil;
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *possibleDevice in devices) {
        if (self.useFrontCam) {
            if ([possibleDevice position] == AVCaptureDevicePositionFront) {
                device = possibleDevice;
            }
        } else {
            if ([possibleDevice position] != AVCaptureDevicePositionFront) {
                device = possibleDevice;
            }
        }
    }
    if (!device) return;

    self.imageDetectionConfidence = 0.0;

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    self.captureSession = session;
    [session beginConfiguration];
    self.captureDevice = device;

    NSError *error = nil;
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    session.sessionPreset = AVCaptureSessionPresetPhoto;
    [session addInput:input];

    AVCaptureVideoDataOutput *dataOutput = [[AVCaptureVideoDataOutput alloc] init];
    [dataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [dataOutput setVideoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
    [dataOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    [session addOutput:dataOutput];

    self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
    [session addOutput:self.stillImageOutput];

    AVCaptureConnection *connection = [dataOutput.connections firstObject];
    [connection setVideoOrientation:AVCaptureVideoOrientationPortrait];

    if (device.isFlashAvailable)
    {
        [device lockForConfiguration:nil];
        [device setFlashMode:AVCaptureFlashModeOff];
        [device unlockForConfiguration];

        if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
        {
            [device lockForConfiguration:nil];
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
            [device unlockForConfiguration];
        }
    }

    [session commitConfiguration];
}

- (void)setCameraViewType:(IPDFCameraViewType)cameraViewType
{
    UIBlurEffect * effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *viewWithBlurredBackground =[[UIVisualEffectView alloc] initWithEffect:effect];
    viewWithBlurredBackground.frame = self.bounds;
    [self insertSubview:viewWithBlurredBackground aboveSubview:_glkView];

    _cameraViewType = cameraViewType;


    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^
    {
        [viewWithBlurredBackground removeFromSuperview];
    });
}

-(void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if (self.forceStop) return;
    if (_isStopped || self.isCapturing || !CMSampleBufferIsValid(sampleBuffer)) return;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];

    if (self.cameraViewType != IPDFCameraViewTypeNormal)
    {
        image = [self filteredImageUsingEnhanceFilterOnImage:image];
    }
    else
    {
        image = [self filteredImageUsingContrastFilterOnImage:image];
    }

    if (self.isBorderDetectionEnabled)
    {
        if (_borderDetectFrame)
        {
            _borderDetectLastRectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:image]];
            _borderDetectFrame = NO;
        }

        if (_borderDetectLastRectangleFeature)
        {
            self.imageDetectionConfidence += .5;

            image = [self drawHighlightOverlayForPoints:image topLeft:_borderDetectLastRectangleFeature.topLeft topRight:_borderDetectLastRectangleFeature.topRight bottomLeft:_borderDetectLastRectangleFeature.bottomLeft bottomRight:_borderDetectLastRectangleFeature.bottomRight];
        }
        else
        {
            self.imageDetectionConfidence = 0.0f;
        }
    }

    if (self.context && _coreImageContext)
    {
        [_coreImageContext drawImage:image inRect:self.bounds fromRect:image.extent];
        [self.context presentRenderbuffer:GL_RENDERBUFFER];

        [_glkView setNeedsDisplay];
    }
}

- (void)enableBorderDetectFrame
{
    _borderDetectFrame = YES;
}

- (CIImage *)drawHighlightOverlayForPoints:(CIImage *)image topLeft:(CGPoint)topLeft topRight:(CGPoint)topRight bottomLeft:(CGPoint)bottomLeft bottomRight:(CGPoint)bottomRight
{
    CIImage *overlay = [CIImage imageWithColor:[[CIColor alloc] initWithColor:self.overlayColor]];
    overlay = [overlay imageByCroppingToRect:image.extent];
    overlay = [overlay imageByApplyingFilter:@"CIPerspectiveTransformWithExtent" withInputParameters:@{@"inputExtent":[CIVector vectorWithCGRect:image.extent],@"inputTopLeft":[CIVector vectorWithCGPoint:topLeft],@"inputTopRight":[CIVector vectorWithCGPoint:topRight],@"inputBottomLeft":[CIVector vectorWithCGPoint:bottomLeft],@"inputBottomRight":[CIVector vectorWithCGPoint:bottomRight]}];

    return [overlay imageByCompositingOverImage:image];
}

- (void)start
{
    _isStopped = NO;

    dispatch_queue_t globalQueue =  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    dispatch_async(globalQueue, ^{
        [self.captureSession startRunning];
    });
    // [self.captureSession startRunning];

    float detectionRefreshRate = _detectionRefreshRateInMS;
    CGFloat detectionRefreshRateInSec = detectionRefreshRate/100;

    if (_lastDetectionRate != _detectionRefreshRateInMS) {
        if (_borderDetectTimeKeeper) {
            [_borderDetectTimeKeeper invalidate];
        }
        _borderDetectTimeKeeper = [NSTimer scheduledTimerWithTimeInterval:detectionRefreshRateInSec target:self selector:@selector(enableBorderDetectFrame) userInfo:nil repeats:YES];
    }

    [self hideGLKView:NO completion:nil];

    _lastDetectionRate = _detectionRefreshRateInMS;
}

- (void)stop
{
    _isStopped = YES;

    dispatch_queue_t globalQueue =  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    dispatch_async(globalQueue, ^{
        [self.captureSession stopRunning];
    });
    // [self.captureSession stopRunning];

    [_borderDetectTimeKeeper invalidate];

    [self hideGLKView:YES completion:nil];
}

- (void)setEnableTorch:(BOOL)enableTorch
{
    _enableTorch = enableTorch;

    AVCaptureDevice *device = self.captureDevice;
    if ([device hasTorch] && [device hasFlash])
    {
        [device lockForConfiguration:nil];
        if (enableTorch)
        {
            [device setTorchMode:AVCaptureTorchModeOn];
        }
        else
        {
            [device setTorchMode:AVCaptureTorchModeOff];
        }
        [device unlockForConfiguration];
    }
}

- (void)setUseFrontCam:(BOOL)useFrontCam
{
    _useFrontCam = useFrontCam;
    [self stop];
    [self setupCameraView];
    [self start];
}


- (void)setContrast:(float)contrast
{

    _contrast = contrast;
}

- (void)setSaturation:(float)saturation
{
    _saturation = saturation;
}

- (void)setBrightness:(float)brightness
{
    _brightness = brightness;
}

- (void)setDetectionRefreshRateInMS:(NSInteger)detectionRefreshRateInMS
{
    _detectionRefreshRateInMS = detectionRefreshRateInMS;
}


- (void)focusAtPoint:(CGPoint)point completionHandler:(void(^)(void))completionHandler
{
    AVCaptureDevice *device = self.captureDevice;
    CGPoint pointOfInterest = CGPointZero;
    CGSize frameSize = self.bounds.size;
    pointOfInterest = CGPointMake(point.y / frameSize.height, 1.f - (point.x / frameSize.width));

    if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus])
    {
        NSError *error;
        if ([device lockForConfiguration:&error])
        {
            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
            {
                [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
                [device setFocusPointOfInterest:pointOfInterest];
            }

            if([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
            {
                [device setExposurePointOfInterest:pointOfInterest];
                [device setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
                completionHandler();
            }

            [device unlockForConfiguration];
        }
    }
    else
    {
        completionHandler();
    }
}

- (void)detectImageRectWithCompletionHander:(UIImage*)image completionHandler:(void(^)(UIImage *data, UIImage *initialData, CIRectangleFeature *rectangleFeature))completionHandler;
{
    __weak typeof(self) weakSelf = self;

    [weakSelf hideGLKView:YES completion:^
    {
        [weakSelf hideGLKView:NO completion:^
        {
            [weakSelf hideGLKView:YES completion:nil];
        }];
    }];
    
    CIImage* enhancedImage = [CIImage imageWithCGImage:image.CGImage];
     if (weakSelf.cameraViewType == IPDFCameraViewTypeBlackAndWhite)
     {
         enhancedImage = [self filteredImageUsingEnhanceFilterOnImage:enhancedImage];
     }
     else
     {
         enhancedImage = [self filteredImageUsingContrastFilterOnImage:enhancedImage];
     }

     if (weakSelf.isBorderDetectionEnabled && rectangleDetectionConfidenceHighEnough(weakSelf.imageDetectionConfidence))
     {
        CIRectangleFeature *rectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:enhancedImage]];

        if (rectangleFeature)
        {
            enhancedImage = [self correctPerspectiveForImage:enhancedImage withFeatures:rectangleFeature];

            UIGraphicsBeginImageContext(CGSizeMake(enhancedImage.extent.size.height, enhancedImage.extent.size.width));
            [[UIImage imageWithCIImage:enhancedImage scale:1.0 orientation:UIImageOrientationRight] drawInRect:CGRectMake(0,0, enhancedImage.extent.size.height, enhancedImage.extent.size.width)];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();

            UIImage *filteredImage = [self doBinarize:image];
            UIImage *cropedImage = [self doBinarize:img];

            [weakSelf hideGLKView:NO completion:nil];
            completionHandler(cropedImage, filteredImage, rectangleFeature);
        } else {
            [weakSelf hideGLKView:NO completion:nil];
            UIImage *filteredImage = [self doBinarize:image];
            completionHandler(filteredImage, filteredImage, nil);
        }
     } else {
         [weakSelf hideGLKView:NO completion:nil];
         UIImage *filteredImage = [self doBinarize:image];
         completionHandler(filteredImage, filteredImage, nil);
     }
}

- (void)captureImageWithCompletionHander:(void(^)(UIImage *data, UIImage *initialData, CIRectangleFeature *rectangleFeature))completionHandler;
{
    if (self.isCapturing) return;
    self.isCapturing = true;

    __weak typeof(self) weakSelf = self;

    [weakSelf hideGLKView:YES completion:^
    {
        [weakSelf hideGLKView:NO completion:^
        {
            [weakSelf hideGLKView:YES completion:nil];
        }];
    }];

    AVCaptureConnection *videoConnection = nil;
    for (AVCaptureConnection *connection in self.stillImageOutput.connections)
    {
        for (AVCaptureInputPort *port in [connection inputPorts])
        {
            if ([[port mediaType] isEqual:AVMediaTypeVideo] )
            {
                videoConnection = connection;
                break;
            }
        }
        if (videoConnection) break;
    }

    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:videoConnection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error)
     {
         NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];

         if (weakSelf.cameraViewType == IPDFCameraViewTypeBlackAndWhite || weakSelf.isBorderDetectionEnabled)
         {
             CIImage *enhancedImage = [CIImage imageWithData:imageData];

             if (weakSelf.cameraViewType == IPDFCameraViewTypeBlackAndWhite)
             {
                 enhancedImage = [self filteredImageUsingEnhanceFilterOnImage:enhancedImage];
             }
             else
             {
                 enhancedImage = [self filteredImageUsingContrastFilterOnImage:enhancedImage];
             }

             if (weakSelf.isBorderDetectionEnabled && rectangleDetectionConfidenceHighEnough(weakSelf.imageDetectionConfidence))
             {
                 CIRectangleFeature *rectangleFeature = [self biggestRectangleInRectangles:[[self highAccuracyRectangleDetector] featuresInImage:enhancedImage]];

                 if (rectangleFeature)
                 {
                     enhancedImage = [self correctPerspectiveForImage:enhancedImage withFeatures:rectangleFeature];

                     UIGraphicsBeginImageContext(CGSizeMake(enhancedImage.extent.size.height, enhancedImage.extent.size.width));
                     [[UIImage imageWithCIImage:enhancedImage scale:1.0 orientation:UIImageOrientationRight] drawInRect:CGRectMake(0,0, enhancedImage.extent.size.height, enhancedImage.extent.size.width)];
                     UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
                     UIImage *initialImage = [UIImage imageWithData:imageData];
                     UIGraphicsEndImageContext();

                     UIImage *filteredImage = [self doBinarize:initialImage];
                     UIImage *cropedImage = [self doBinarize:image];

                     [weakSelf hideGLKView:NO completion:nil];
                     completionHandler(cropedImage, filteredImage, rectangleFeature);
                 } else {
                     [weakSelf hideGLKView:NO completion:nil];
                     UIImage *initialImage = [UIImage imageWithData:imageData];
                     UIImage *filteredImage = [self doBinarize:initialImage];
                     completionHandler(filteredImage, filteredImage, nil);
                 }
             } else {
                 [weakSelf hideGLKView:NO completion:nil];
                 UIImage *initialImage = [UIImage imageWithData:imageData];
                 UIImage *filteredImage = [self doBinarize:initialImage];
                 completionHandler(filteredImage, filteredImage, nil);
             }

         }
         else
         {
             [weakSelf hideGLKView:NO completion:nil];
             UIImage *initialImage = [UIImage imageWithData:imageData];
             UIImage *filteredImage = [self doBinarize:initialImage];
             completionHandler(filteredImage, filteredImage, nil);
         }

         weakSelf.isCapturing = NO;
     }];
}

- (void)hideGLKView:(BOOL)hidden completion:(void(^)(void))completion
{
    [UIView animateWithDuration:0.1 animations:^
    {
        self->_glkView.alpha = (hidden) ? 0.0 : 1.0;
    }
    completion:^(BOOL finished)
    {
        if (!completion) return;
        completion();
    }];
}

- (UIImage *)doBinarize:(UIImage *)sourceImage
{
    // [self start];
    UIImageOrientation orientation = sourceImage.imageOrientation;
    CIImage* image = [CIImage imageWithCGImage:sourceImage.CGImage];
    CIContext *context = [CIContext contextWithOptions:nil];
    
//    CIFilter *filter = [CIFilter filterWithName:@"CIPhotoEffectTransfer"];
//    [filter setValue:image forKey:kCIInputImageKey];
    
    CIFilter *filter = [CIFilter filterWithName:@"CIPhotoEffectNoir" keysAndValues: kCIInputImageKey,image, nil];
    
//    CIFilter *filter= [CIFilter filterWithName:@"CIColorControls"];
//    [filter setValue:image forKey:@"inputImage"];
//    [filter setValue:[NSNumber numberWithFloat:0.6] forKey:@"inputSaturation"];
////    [filter setValue:[NSNumber numberWithFloat:0.2] forKey:@"inputBrightness"];
//    [filter setValue:[NSNumber numberWithFloat:1.5] forKey:@"inputContrast"];//1.05
    
    CIImage *outputImage = [filter outputImage];
    CGImageRef cgimg = [context createCGImage:outputImage fromRect:[outputImage extent]];
    UIImage *newPhoto = [UIImage imageWithCGImage:cgimg scale:1.0 orientation:orientation];
    CGImageRelease(cgimg);
    context = nil;
//    return newPhoto;
    return [self grayImage:newPhoto];
    
    /*
    CIContext *imageContext = [CIContext contextWithOptions:nil];
    CIImage *image = [[CIImage alloc] initWithImage:sourceImage];
    
    CIFilter *filter= [CIFilter filterWithName:@"CIColorControls"];
    [filter setValue:image forKey:@"inputImage"];
    [filter setValue:[NSNumber numberWithFloat:0] forKey:@"inputSaturation"];
    [filter setValue:[NSNumber numberWithFloat:1.05] forKey:@"inputContrast"];//1.05
    
    CIImage *result = [filter valueForKey: @"outputImage"];
    CGImageRef cgImageRef = [imageContext createCGImage:result fromRect:[result extent]];
    
    UIImage *targetImage = [UIImage imageWithCGImage:cgImageRef];
    return targetImage;
     */
    
    /*
//    UIImage *image = [[UIImage alloc] initWithCIImage:sourceImage];
    UIImage *image = [self grayImage:sourceImage];
    return image;
    
    // [self start];
    CIImage * ciImage = [CIFilter filterWithName:@"CIColorControls" keysAndValues:kCIInputImageKey, image.CIImage, @"inputBrightness", @(self.brightness), @"inputContrast", @(self.contrast), @"inputSaturation", @(self.saturation), nil].outputImage;
//    CIImage * ciImage = [CIFilter filterWithName:@"CIColorControls" keysAndValues:kCIInputImageKey, image.CIImage, @"inputBrightness", 0.6, @"inputContrast", 1.5, @"inputSaturation", 0.8, nil].outputImage;

    return [[UIImage alloc] initWithCIImage:ciImage];
*/
//     //first off, try to grayscale the image using iOS core Image routine
//     UIImage * grayScaledImg = [self grayImage:sourceImage];
//     GPUImagePicture *imageSource = [[GPUImagePicture alloc] initWithImage:grayScaledImg];
//     GPUImageAdaptiveThresholdFilter *stillImageFilter = [[GPUImageAdaptiveThresholdFilter alloc] init];
//     stillImageFilter.blurSize = 8.0;

//     [imageSource addTarget:stillImageFilter];
//     [imageSource processImage];

//     UIImage *retImage = [stillImageFilter imageFromCurrentlyProcessedOutput];
//     return retImage;
}

- (UIImage *) grayImage :(UIImage *)inputImage
{    
    // Create a graphic context.
    UIGraphicsBeginImageContextWithOptions(inputImage.size, YES, 1.0);
    CGRect imageRect = CGRectMake(0, 0, inputImage.size.width, inputImage.size.height);

    // Draw the image with the luminosity blend mode.
    // On top of a white background, this will give a black and white image.
    [inputImage drawInRect:imageRect blendMode:kCGBlendModeLuminosity alpha:1.0];

    // Get the resulting image.
    UIImage *outputImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return outputImage;
}

- (CIImage *)filteredImageUsingEnhanceFilterOnImage:(CIImage *)image
{
    [self start];
    return [CIFilter filterWithName:@"CIColorControls" keysAndValues:kCIInputImageKey, image, @"inputBrightness", @(self.brightness), @"inputContrast", @(self.contrast), @"inputSaturation", @(self.saturation), nil].outputImage;
}

- (CIImage *)filteredImageUsingContrastFilterOnImage:(CIImage *)image
{
    return [CIFilter filterWithName:@"CIColorControls" withInputParameters:@{@"inputContrast":@(1.0),kCIInputImageKey:image}].outputImage;
}

- (CIImage *)correctPerspectiveForImage:(CIImage *)image withFeatures:(CIRectangleFeature *)rectangleFeature
{
  NSMutableDictionary *rectangleCoordinates = [NSMutableDictionary new];
  CGPoint newLeft = CGPointMake(rectangleFeature.topLeft.x + 30, rectangleFeature.topLeft.y);
  CGPoint newRight = CGPointMake(rectangleFeature.topRight.x, rectangleFeature.topRight.y);
  CGPoint newBottomLeft = CGPointMake(rectangleFeature.bottomLeft.x + 30, rectangleFeature.bottomLeft.y);
  CGPoint newBottomRight = CGPointMake(rectangleFeature.bottomRight.x, rectangleFeature.bottomRight.y);


  rectangleCoordinates[@"inputTopLeft"] = [CIVector vectorWithCGPoint:newLeft];
  rectangleCoordinates[@"inputTopRight"] = [CIVector vectorWithCGPoint:newRight];
  rectangleCoordinates[@"inputBottomLeft"] = [CIVector vectorWithCGPoint:newBottomLeft];
  rectangleCoordinates[@"inputBottomRight"] = [CIVector vectorWithCGPoint:newBottomRight];
  return [image imageByApplyingFilter:@"CIPerspectiveCorrection" withInputParameters:rectangleCoordinates];
}

- (CIDetector *)rectangleDetetor
{
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
          detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil options:@{CIDetectorAccuracy : CIDetectorAccuracyLow,CIDetectorTracking : @(YES)}];
    });
    return detector;
}

- (CIDetector *)highAccuracyRectangleDetector
{
    static CIDetector *detector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        detector = [CIDetector detectorOfType:CIDetectorTypeRectangle context:nil options:@{CIDetectorAccuracy : CIDetectorAccuracyHigh, CIDetectorReturnSubFeatures: @(YES) }];
    });
    return detector;
}

- (CIRectangleFeature *)biggestRectangleInRectangles:(NSArray *)rectangles
{
    if (![rectangles count]) return nil;

    float halfPerimiterValue = 0;

    CIRectangleFeature *biggestRectangle = [rectangles firstObject];

    for (CIRectangleFeature *rect in rectangles)
    {
        CGPoint p1 = rect.topLeft;
        CGPoint p2 = rect.topRight;
        CGFloat width = hypotf(p1.x - p2.x, p1.y - p2.y);

        CGPoint p3 = rect.topLeft;
        CGPoint p4 = rect.bottomLeft;
        CGFloat height = hypotf(p3.x - p4.x, p3.y - p4.y);

        CGFloat currentHalfPerimiterValue = height + width;

        if (halfPerimiterValue < currentHalfPerimiterValue)
        {
            halfPerimiterValue = currentHalfPerimiterValue;
            biggestRectangle = rect;
        }
    }

    if (self.delegate) {
        [self.delegate didDetectRectangle:biggestRectangle withType:[self typeForRectangle:biggestRectangle]];
    }

    return biggestRectangle;
}

- (IPDFRectangeType) typeForRectangle: (CIRectangleFeature*) rectangle {
    if (fabs(rectangle.topRight.y - rectangle.topLeft.y) > 100 ||
        fabs(rectangle.topRight.x - rectangle.bottomRight.x) > 100 ||
        fabs(rectangle.topLeft.x - rectangle.bottomLeft.x) > 100 ||
        fabs(rectangle.bottomLeft.y - rectangle.bottomRight.y) > 100) {
        return IPDFRectangeTypeBadAngle;
    } else if ((_glkView.frame.origin.y + _glkView.frame.size.height) - rectangle.topLeft.y > 150 ||
               (_glkView.frame.origin.y + _glkView.frame.size.height) - rectangle.topRight.y > 150 ||
               _glkView.frame.origin.y - rectangle.bottomLeft.y > 150 ||
               _glkView.frame.origin.y - rectangle.bottomRight.y > 150) {
        return IPDFRectangeTypeTooFar;
    }
    return IPDFRectangeTypeGood;
}

BOOL rectangleDetectionConfidenceHighEnough(float confidence)
{
    return (confidence > 1.0);
}

@end
