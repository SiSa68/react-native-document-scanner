import React from 'react'
import {
  DeviceEventEmitter,
  findNodeHandle,
  NativeModules,
  Platform,
  requireNativeComponent,
  ViewStyle } from 'react-native'

const RNPdfScanner = requireNativeComponent('RNPdfScanner')
const ScannerManager = NativeModules.RNPdfScannerManager

class PdfScanner extends React.Component {
  sendOnPictureTakenEvent (event) {
    if (!this.props.onPictureTaken) return null
    return this.props.onPictureTaken(event.nativeEvent)
  }

  sendOnRectangleDetectEvent (event) {
    if (!this.props.onRectangleDetect) return null
    return this.props.onRectangleDetect(event.nativeEvent)
  }

  sendOnStartProcessingEvent (event) {
    if (!this.props.onProcessing) return null
    return this.props.onProcessing(event.nativeEvent)
  }

  getImageQuality () {
    if (!this.props.quality) return 0.8
    if (this.props.quality > 1) return 1
    if (this.props.quality < 0.1) return 0.1
    return this.props.quality
  }

  componentDidMount () {
    if (Platform.OS === 'android') {
      const { onPictureTaken, onProcessing } = this.props
      if (onPictureTaken) DeviceEventEmitter.addListener('onScanTaken', onPictureTaken)
      if (onProcessing) DeviceEventEmitter.addListener('onProcessingChange', onProcessing)
    }
  }

  componentDidUpdate(prevProps) {
    if (Platform.OS === 'android') {
      if (this.props.onPictureTaken !== prevProps.onPictureTaken) {
        if (prevProps.onPictureTaken)
          DeviceEventEmitter.removeListener('onScanTaken', prevProps.onPictureTaken)
        if (this.props.onPictureTaken)
          DeviceEventEmitter.addListener('onScanTaken', this.props.onPictureTaken)
      }
      if (this.props.onProcessing !== prevProps.onProcessing) {
        if (prevProps.onProcessing)
          DeviceEventEmitter.removeListener('onProcessingChange', prevProps.onProcessing)
        if (this.props.onProcessing)
          DeviceEventEmitter.addListener('onProcessingChange', this.props.onProcessing)
      }
    }
  }

  componentWillUnmount () {
    if (Platform.OS === 'android') {
      const { onPictureTaken, onProcessing } = this.props
      if (onPictureTaken) DeviceEventEmitter.removeListener('onScanTaken', onPictureTaken)
      if (onProcessing) DeviceEventEmitter.removeListener('onProcessingChange', onProcessing)
    }
  }

  capture () {
    // console.log("in capture")
    if (this._scannerHandle) {
      // console.log("in capture in if")
      ScannerManager.capture(this._scannerHandle)
    }
  }

  start () {
    // console.log('this is start');
    if (this._scannerHandle)
      ScannerManager.start(this._scannerHandle);
  }

  stop () {
    // console.log('this is stop');
    if (this._scannerHandle)
      ScannerManager.stop(this._scannerHandle);
  }

  _scannerRef = null;
  _scannerHandle = null;
  _setReference = (ref) => {
    if (ref) {
      this._scannerRef = ref
      this._scannerHandle = findNodeHandle(ref)
    } else {
      this._scannerRef = null
      this._scannerHandle = null
    }
  };

  render () {
    // 1
    return (
      <RNPdfScanner
        ref={this._setReference}
        {...this.props}
        onScanTaken={this.sendOnPictureTakenEvent.bind(this)}
        onRectangleDetect={this.sendOnRectangleDetectEvent.bind(this)}
        onProcessing={this.sendOnStartProcessingEvent.bind(this)}
        useFrontCam={this.props.useFrontCam || false}
        brightness={this.props.brightness || 0}
        saturation={this.props.saturation || 1}
        contrast={this.props.contrast || 1}
        quality={this.getImageQuality()}
        
        detectionCountBeforeCapture={this.props.detectionCountBeforeCapture || 5}
        durationBetweenCaptures={this.props.durationBetweenCaptures || 0}
        detectionRefreshRateInMS={this.props.detectionRefreshRateInMS || 50}
      />
    )
  }
}

export const onImagePicked = (imageUri, callback) => {
    // console.log("is this here really?");
    ScannerManager.processPickedImage(imageUri, callback);
}

export default PdfScanner
