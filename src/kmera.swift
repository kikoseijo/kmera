//
//  kmera.swift
//  kmera
//
//  Created by sMac on 29/01/2017.
//  Copyright © 2017 Sunnyface.com. All rights reserved.
//

import UIKit
import Photos
import AVFoundation


public enum KMeraState {
    case ready, accessDenied, noDeviceFound, notDetermined
}

public enum KMeraDevice {
    case front, back
}

public enum KMeraFlashMode: Int {
    case off, on, auto
}

public enum KMeraFocusMode: Int {
    case off, on, auto
}

public enum KMeraOutputMode {
    case stillImage, videoWithMic, videoOnly
}

public enum KMeraOutputQuality: Int {
    case low, medium, high
}

enum KMeraSafeUpdateModes {
    case zoom, focus, torch
}



open class KMera: NSObject {
    
    // MARK: - Properties
    
    open var kSession: AVCaptureSession?
    open var showDebug = false
    open var displayAccessPermissions = true
    open var torchLevel = 0.1
    open var printLog:(_ title: String, _ msg: String) -> Void = { (title: String, msg: String) -> Void in
        
        var alert = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { (alertAction) -> Void in  }))
        
        if let rootController = UIApplication.shared.keyWindow?.rootViewController {
            rootController.present(alert, animated: true, completion:nil)
        }
    }
    
    open var savePhotosToUserLibrary = true
    open var enableOrientationChanges = true {
        didSet {
            if enableOrientationChanges {
                addOrientationObserver()
            } else {
                removeOrientationObserver()
            }
        }
    }
    
    /// The Bool property to determine if the camera is ready to use.
    open var cameraIsReady: Bool {
        get {
            return cameraIsSetup
        }
    }
    
    /// The Bool property to determine if current device has front camera.
    open var hasFrontCamera: Bool = {
        let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo)
        for  device in devices!  {
            let captureDevice = device as! AVCaptureDevice
            if (captureDevice.position == .front) {
                return true
            }
        }
        return false
    }()
    
    /// The Bool property to determine if current device has flash.
    open var hasFlash: Bool = {
        let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo)
        for  device in devices!  {
            let captureDevice = device as! AVCaptureDevice
            if (captureDevice.position == .back) {
                return captureDevice.hasFlash
            }
        }
        return false
    }()
    
    /// Property to change camera device between front and back.
    open var cameraDevice = KMeraDevice.back {
        didSet {
            if cameraIsSetup {
                if cameraDevice != oldValue {
                    changeCamera(cameraDevice)
                    updateMaxZoomScale()
                    applyZoom(0)
                }
            }
        }
    }
    
    /// Property to change camera flash mode.
    open var flashMode = KMeraFlashMode.off {
        didSet {
            if cameraIsSetup {
                if flashMode != oldValue {
                    changeFlashMode(flashMode)
                }
            }
        }
    }
    
    /// Property to change camera output quality.
    open var cameraOutputQuality = KMeraOutputQuality.high {
        didSet {
            if cameraIsSetup {
                if cameraOutputQuality != oldValue {
                    changeQualityMode(cameraOutputQuality)
                }
            }
        }
    }
    
    /// Property to change camera output.
    open var cameraOutputMode = KMeraOutputMode.stillImage {
        didSet {
            if cameraIsSetup {
                if cameraOutputMode != oldValue {
                    _setupOutputMode(cameraOutputMode, oldCameraOutputMode: oldValue)
                }
                updateMaxZoomScale()
                applyZoom(0)
            }
        }
    }
    
    /// Property to check video recording duration when in progress
    open var recordedDuration : CMTime { return movieOutput?.recordedDuration ?? kCMTimeZero }
    
    /// Property to check video recording file size when in progress
    open var recordedFileSize : Int64 { return movieOutput?.recordedFileSize ?? 0 }
    
    
    // MARK: - Private properties
    
    fileprivate weak var embeddingView: UIView?
    fileprivate var videoCompletion: ((_ videoURL: URL?, _ error: NSError?) -> Void)?
    
    fileprivate var sessionQueue: DispatchQueue = DispatchQueue(label: "CameraSessionQueue", attributes: [])
    
    fileprivate lazy var frontCameraDevice: AVCaptureDevice? = {
        let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo) as! [AVCaptureDevice]
        return devices.filter{$0.position == .front}.first
    }()
    
    fileprivate lazy var backCameraDevice: AVCaptureDevice? = {
        let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo) as! [AVCaptureDevice]
        return devices.filter{$0.position == .back}.first
    }()
    
    fileprivate lazy var mic: AVCaptureDevice? = {
        return AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeAudio)
    }()
    
    fileprivate var stillImageOutput: AVCaptureStillImageOutput?
    fileprivate var movieOutput: AVCaptureMovieFileOutput?
    fileprivate var previewLayer: AVCaptureVideoPreviewLayer?
    fileprivate var library: PHPhotoLibrary?
    
    fileprivate var cameraIsSetup = false
    fileprivate var cameraIsObservingDeviceOrientation = false
    
    fileprivate var zoomScale       = CGFloat(1.0)
    fileprivate var beginZoomScale  = CGFloat(1.0)
    fileprivate var maxZoomScale    = CGFloat(1.0)
    
    fileprivate var tempFilePath: URL = {
        let tempPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tempMovie").appendingPathExtension("mp4").absoluteString
        if FileManager.default.fileExists(atPath: tempPath) {
            do {
                try FileManager.default.removeItem(atPath: tempPath)
            } catch { }
        }
        return URL(string: tempPath)!
    }()
    
    
    // MARK: - KMera
    
    
    open func addPreviewLayerToView(_ view: UIView) -> KMeraState {
        return addPreviewLayerToView(view, newCameraOutputMode: cameraOutputMode)
    }
    open func addPreviewLayerToView(_ view: UIView, newCameraOutputMode: KMeraOutputMode) -> KMeraState {
        return addLayerPreviewToView(view, newCameraOutputMode: newCameraOutputMode, completion: nil)
    }
    
    open func addLayerPreviewToView(_ view: UIView, newCameraOutputMode: KMeraOutputMode, completion: ((Void) -> Void)?) -> KMeraState {
        if canLoadCamera() {
            if let _ = embeddingView {
                if let validPreviewLayer = previewLayer {
                    validPreviewLayer.removeFromSuperlayer()
                }
            }
            if cameraIsSetup {
                addPreviewLayer(view)
                cameraOutputMode = newCameraOutputMode
                if let validCompletion = completion {
                    validCompletion()
                }
            } else {
                _setupCamera({ Void -> Void in
                    self.addPreviewLayer(view)
                    self.cameraOutputMode = newCameraOutputMode
                    if let validCompletion = completion {
                        validCompletion()
                    }
                })
            }
        }
        return isCameraAvailable()
    }
    

    open func requestCameraPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo, completionHandler: { (alowedAccess) -> Void in
            if self.cameraOutputMode == .videoWithMic {
                AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeAudio, completionHandler: { (alowedAccess) -> Void in
                    DispatchQueue.main.sync(execute: { () -> Void in
                        completion(alowedAccess)
                    })
                })
            } else {
                DispatchQueue.main.sync(execute: { () -> Void in
                    completion(alowedAccess)
                })
                
            }
        })
    }
    
    /**
     Stops running capture session but all setup devices, inputs and outputs stay for further reuse.
     */
    open func stopCaptureSession() {
        kSession?.stopRunning()
        removeOrientationObserver()
    }
    
    /**
     Resumes capture session.
     */
    open func resumeCaptureSession() {
        if let validCaptureSession = kSession {
            if !validCaptureSession.isRunning && cameraIsSetup {
                validCaptureSession.startRunning()
                addOrientationObserver()
            }
        } else {
            if canLoadCamera() {
                if cameraIsSetup {
                    stopAndRemoveCaptureSession()
                }
                _setupCamera({Void -> Void in
                    if let validEmbeddingView = self.embeddingView {
                        self.addPreviewLayer(validEmbeddingView)
                    }
                    self.addOrientationObserver()
                })
            }
        }
    }
    
    /**
     Stops running capture session and removes all setup devices, inputs and outputs.
     */
    open func stopAndRemoveCaptureSession() {
        stopCaptureSession()
        cameraDevice = .back
        cameraIsSetup = false
        previewLayer = nil
        kSession = nil
        frontCameraDevice = nil
        backCameraDevice = nil
        mic = nil
        stillImageOutput = nil
        movieOutput = nil
    }
    
    
    
    /**
     Starts recording a video with or without voice as in the session preset.
     */
    open func startRecordingVideo() {
        if cameraOutputMode != .stillImage {
            _getMovieOutput().startRecording(toOutputFileURL: tempFilePath, recordingDelegate: self)
        } else {
            log(NSLocalizedString("Capture session output still image", comment:""), message: NSLocalizedString("I can only take pictures", comment:""))
        }
    }
    
    /**
     Stop recording a video. Save it to the cameraRoll and give back the url.
     */
    open func stopVideoRecording(_ completion:((_ videoURL: URL?, _ error: NSError?) -> Void)?) {
        if let runningMovieOutput = movieOutput {
            if runningMovieOutput.isRecording {
                videoCompletion = completion
                runningMovieOutput.stopRecording()
            }
        }
    }
    
    
    open func currentCameraStatus() -> KMeraState {
        return isCameraAvailable()
    }
    
    open func changeFlashMode() -> KMeraFlashMode {
        flashMode = KMeraFlashMode(rawValue: (flashMode.rawValue+1)%3)!
        return flashMode
    }
   
    open func changeQualityMode() -> KMeraOutputQuality {
        cameraOutputQuality = KMeraOutputQuality(rawValue: (cameraOutputQuality.rawValue+1)%3)!
        return cameraOutputQuality
    }
    
    // MARK: -
    
    
    
    fileprivate func saveVideoToLibrary(_ fileURL: URL) {
        if let validLibrary = library {
            validLibrary.performChanges({
                
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }, completionHandler: { success, error in
                if (error != nil) {
                    self.log(NSLocalizedString("Unable to save video to the iPhone.", comment:""), message: error!.localizedDescription)
                    self._executeVideoCompletionWithURL(nil, error: error as NSError?)
                } else {
                    self._executeVideoCompletionWithURL(fileURL, error: error as NSError?)
                }
            })
        }
    }
    
    
    
    fileprivate func applyZoom(_ scale: CGFloat) {
        zoomScale = max(1.0, min(beginZoomScale * scale, maxZoomScale))
        safeChangeCameraValue(.zoom, newValue: zoomScale)
    }
    
    fileprivate func safeChangeCameraValue(_ valueMode: KMeraSafeUpdateModes, newValue: CGFloat){
        do {
            let captureDevice = AVCaptureDevice.devices().first as? AVCaptureDevice
            try captureDevice?.lockForConfiguration()
            
            switch valueMode {
            case .zoom:
                captureDevice?.videoZoomFactor = newValue
            case .torch:
                try! captureDevice?.setTorchModeOnWithLevel(Float(newValue))
            default: break
                
            }
            captureDevice?.unlockForConfiguration()
        } catch {
            print("Error locking configuration")
        }
        
    }
    
    fileprivate func _executeVideoCompletionWithURL(_ url: URL?, error: NSError?) {
        if let validCompletion = videoCompletion {
            validCompletion(url, error)
            videoCompletion = nil
        }
    }
    
    fileprivate func _getMovieOutput() -> AVCaptureMovieFileOutput {
        var shouldReinitializeMovieOutput = movieOutput == nil
        if !shouldReinitializeMovieOutput {
            if let connection = movieOutput!.connection(withMediaType: AVMediaTypeVideo) {
                shouldReinitializeMovieOutput = shouldReinitializeMovieOutput || !connection.isActive
            }
        }
        
        if shouldReinitializeMovieOutput {
            movieOutput = AVCaptureMovieFileOutput()
            movieOutput!.movieFragmentInterval = kCMTimeInvalid
            
            if let kSession = kSession {
                if kSession.canAddOutput(movieOutput) {
                    kSession.beginConfiguration()
                    kSession.addOutput(movieOutput)
                    kSession.commitConfiguration()
                }
            }
        }
        return movieOutput!
    }
    
    fileprivate func _getStillImageOutput() -> AVCaptureStillImageOutput {
        var shouldReinitializeStillImageOutput = stillImageOutput == nil
        if !shouldReinitializeStillImageOutput {
            if let connection = stillImageOutput!.connection(withMediaType: AVMediaTypeVideo) {
                shouldReinitializeStillImageOutput = shouldReinitializeStillImageOutput || !connection.isActive
            }
        }
        if shouldReinitializeStillImageOutput {
            stillImageOutput = AVCaptureStillImageOutput()
            
            if let kSession = kSession {
                if kSession.canAddOutput(stillImageOutput) {
                    kSession.beginConfiguration()
                    kSession.addOutput(stillImageOutput)
                    kSession.commitConfiguration()
                }
            }
        }
        return stillImageOutput!
    }
    
    @objc fileprivate func _orientationChanged() {
        var currentConnection: AVCaptureConnection?;
        switch cameraOutputMode {
        case .stillImage:
            currentConnection = stillImageOutput?.connection(withMediaType: AVMediaTypeVideo)
        case .videoOnly, .videoWithMic:
            currentConnection = _getMovieOutput().connection(withMediaType: AVMediaTypeVideo)
        }
        if let validPreviewLayer = previewLayer {
            if let validPreviewLayerConnection = validPreviewLayer.connection {
                if validPreviewLayerConnection.isVideoOrientationSupported {
                    validPreviewLayerConnection.videoOrientation = currentVideoOrientation()
                }
            }
            if let validOutputLayerConnection = currentConnection {
                if validOutputLayerConnection.isVideoOrientationSupported {
                    validOutputLayerConnection.videoOrientation = currentVideoOrientation()
                }
            }
            DispatchQueue.main.async(execute: { () -> Void in
                if let validEmbeddingView = self.embeddingView {
                    validPreviewLayer.frame = validEmbeddingView.bounds
                }
            })
        }
    }
    
    fileprivate func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
    
    fileprivate func canLoadCamera() -> Bool {
        let currentCameraState = isCameraAvailable()
        return currentCameraState == .ready || (currentCameraState == .notDetermined && displayAccessPermissions)
    }
    
    fileprivate func _setupCamera(_ completion: @escaping (Void) -> Void) {
        kSession = AVCaptureSession()
        
        sessionQueue.async(execute: {
            if let validCaptureSession = self.kSession {
                validCaptureSession.beginConfiguration()
                validCaptureSession.sessionPreset = AVCaptureSessionPresetHigh
                self.changeCamera(self.cameraDevice)
                self._setupOutputs()
                self._setupOutputMode(self.cameraOutputMode, oldCameraOutputMode: nil)
                self._setupPreviewLayer()
                validCaptureSession.commitConfiguration()
                self.changeFlashMode(self.flashMode)
                self.changeQualityMode(self.cameraOutputQuality)
                validCaptureSession.startRunning()
                self.addOrientationObserver()
                self.cameraIsSetup = true
                self._orientationChanged()
                
                completion()
            }
        })
    }
    
    fileprivate func addOrientationObserver() {
        if enableOrientationChanges && !cameraIsObservingDeviceOrientation {
            NotificationCenter.default.addObserver(self, selector: #selector(KMera._orientationChanged), name: NSNotification.Name.UIDeviceOrientationDidChange, object: nil)
            cameraIsObservingDeviceOrientation = true
        }
    }
    
    fileprivate func removeOrientationObserver() {
        if cameraIsObservingDeviceOrientation {
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIDeviceOrientationDidChange, object: nil)
            cameraIsObservingDeviceOrientation = false
        }
    }
    
    fileprivate func addPreviewLayer(_ view: UIView) {
        embeddingView = view
        attachZoom(view)
        DispatchQueue.main.async(execute: { () -> Void in
            guard let _ = self.previewLayer else {
                return
            }
            self.previewLayer!.frame = view.layer.bounds
            view.clipsToBounds = true
            view.layer.addSublayer(self.previewLayer!)
        })
    }
    
    fileprivate func updateMaxZoomScale() {
        var maxZoom = CGFloat(1.0)
        beginZoomScale = CGFloat(1.0)
        
        if cameraDevice == .back {
            maxZoom = (backCameraDevice?.activeFormat.videoMaxZoomFactor)!
        }
        else if cameraDevice == .front {
            maxZoom = (frontCameraDevice?.activeFormat.videoMaxZoomFactor)!
        }
        
        maxZoomScale = maxZoom
    }
    
    fileprivate func isCameraAvailable() -> KMeraState {
        let deviceHasCamera = UIImagePickerController.isCameraDeviceAvailable(UIImagePickerControllerCameraDevice.rear) || UIImagePickerController.isCameraDeviceAvailable(UIImagePickerControllerCameraDevice.front)
        if deviceHasCamera {
            let authorizationStatus = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo)
            let userAgreedToUseIt = authorizationStatus == .authorized
            if userAgreedToUseIt {
                return .ready
            } else if authorizationStatus == AVAuthorizationStatus.notDetermined {
                return .notDetermined
            } else {
                log(NSLocalizedString("Camera access denied", comment:""), message:NSLocalizedString("You need to go to settings app and grant acces to the camera device to use it.", comment:""))
                return .accessDenied
            }
        } else {
            log(NSLocalizedString("Camera unavailable", comment:""), message:NSLocalizedString("The device does not have a camera.", comment:""))
            return .noDeviceFound
        }
    }
    
    fileprivate func _setupOutputMode(_ newCameraOutputMode: KMeraOutputMode, oldCameraOutputMode: KMeraOutputMode?) {
        kSession?.beginConfiguration()
        
        if let cameraOutputToRemove = oldCameraOutputMode {
            // remove current setting
            switch cameraOutputToRemove {
            case .stillImage:
                if let validStillImageOutput = stillImageOutput {
                    kSession?.removeOutput(validStillImageOutput)
                }
            case .videoOnly, .videoWithMic:
                if let validMovieOutput = movieOutput {
                    kSession?.removeOutput(validMovieOutput)
                }
                if cameraOutputToRemove == .videoWithMic {
                    disableAudioRecord()
                }
            }
        }
        
        // configure new devices
        switch newCameraOutputMode {
        case .stillImage:
            if (stillImageOutput == nil) {
                _setupOutputs()
            }
            if let validStillImageOutput = stillImageOutput {
                if let kSession = kSession {
                    if kSession.canAddOutput(validStillImageOutput) {
                        kSession.addOutput(validStillImageOutput)
                    }
                }
            }
        case .videoOnly, .videoWithMic:
            kSession?.addOutput(_getMovieOutput())
            
            if newCameraOutputMode == .videoWithMic {
                if let validMic = getInputDevice(mic) {
                    kSession?.addInput(validMic)
                }
            }
        }
        kSession?.commitConfiguration()
        changeQualityMode(cameraOutputQuality)
        _orientationChanged()
    }
    
    fileprivate func _setupOutputs() {
        if (stillImageOutput == nil) {
            stillImageOutput = AVCaptureStillImageOutput()
        }
        if (movieOutput == nil) {
            movieOutput = AVCaptureMovieFileOutput()
            movieOutput!.movieFragmentInterval = kCMTimeInvalid
        }
        if library == nil {
            library = PHPhotoLibrary.shared()
        }
    }
    
    fileprivate func _setupPreviewLayer() {
        if let validCaptureSession = kSession {
            previewLayer = AVCaptureVideoPreviewLayer(session: validCaptureSession)
            previewLayer?.videoGravity = AVLayerVideoGravityResizeAspectFill
        }
    }
    
    fileprivate func changeCamera(_ deviceType: KMeraDevice) {
        if let validCaptureSession = kSession {
            validCaptureSession.beginConfiguration()
            let inputs = validCaptureSession.inputs as! [AVCaptureInput]
            
            for input in inputs {
                if let deviceInput = input as? AVCaptureDeviceInput {
                    if deviceInput.device == backCameraDevice && cameraDevice == .front {
                        validCaptureSession.removeInput(deviceInput)
                        break;
                    } else if deviceInput.device == frontCameraDevice && cameraDevice == .back {
                        validCaptureSession.removeInput(deviceInput)
                        break;
                    }
                }
            }
            switch cameraDevice {
            case .front:
                if hasFrontCamera {
                    if let validFrontDevice = getInputDevice(frontCameraDevice) {
                        if !inputs.contains(validFrontDevice) {
                            validCaptureSession.addInput(validFrontDevice)
                        }
                    }
                }
            case .back:
                if let validBackDevice = getInputDevice(backCameraDevice) {
                    if !inputs.contains(validBackDevice) {
                        validCaptureSession.addInput(validBackDevice)
                    }
                }
            }
            validCaptureSession.commitConfiguration()
        }
    }
    
    fileprivate func changeFlashMode(_ flashMode: KMeraFlashMode) {
        kSession?.beginConfiguration()
        let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo)
        for  device in devices!  {
            let captureDevice = device as! AVCaptureDevice
            if (captureDevice.position == AVCaptureDevicePosition.back) {
                let avFlashMode = AVCaptureFlashMode(rawValue: flashMode.rawValue)
                if (captureDevice.isFlashModeSupported(avFlashMode!)) {
                    do {
                        try captureDevice.lockForConfiguration()
                    } catch {
                        return
                    }
                    captureDevice.flashMode = avFlashMode!
                    captureDevice.unlockForConfiguration()
                }
            }
        }
        kSession?.commitConfiguration()
    }
    
    fileprivate func changeQualityMode(_ newCameraOutputQuality: KMeraOutputQuality) {
        if let validCaptureSession = kSession {
            var sessionPreset = AVCaptureSessionPresetLow
            switch (newCameraOutputQuality) {
            case .low:
                sessionPreset = AVCaptureSessionPresetLow
            case .medium:
                sessionPreset = AVCaptureSessionPresetMedium
            case .high:
                if cameraOutputMode == .stillImage {
                    sessionPreset = AVCaptureSessionPresetPhoto
                } else {
                    sessionPreset = AVCaptureSessionPresetHigh
                }
            }
            if validCaptureSession.canSetSessionPreset(sessionPreset) {
                validCaptureSession.beginConfiguration()
                validCaptureSession.sessionPreset = sessionPreset
                validCaptureSession.commitConfiguration()
            } else {
                log(NSLocalizedString("Preset not supported", comment:""), message: NSLocalizedString("Camera preset not supported. Please try another one.", comment:""))
            }
        } else {
            log(NSLocalizedString("Camera error", comment:""), message: NSLocalizedString("No valid capture session found, I can't take any pictures or videos.", comment:""))
        }
    }
    
    fileprivate func disableAudioRecord() {
        guard let inputs = kSession?.inputs as? [AVCaptureInput] else { return }
        
        for input in inputs {
            if let deviceInput = input as? AVCaptureDeviceInput {
                if deviceInput.device == mic {
                    kSession?.removeInput(deviceInput)
                    break;
                }
            }
        }
    }
    
    fileprivate func log(_ title: String, message: String) {
        if showDebug {
            DispatchQueue.main.async(execute: { () -> Void in
                self.printLog(title, message)
            })
        }
    }
    
    fileprivate func getInputDevice(_ device: AVCaptureDevice?) -> AVCaptureDeviceInput? {
        guard let validDevice = device else { return nil }
        do {
            return try AVCaptureDeviceInput(device: validDevice)
        } catch let outError {
            log(NSLocalizedString("Device setup error occured", comment:""), message: "\(outError)")
            return nil
        }
    }
    
    deinit {
        stopAndRemoveCaptureSession()
        removeOrientationObserver()
    }
}



// MARK: Closures

extension KMera {
    /**
     Captures still image from currently running capture session.
     
     :param: imageCompletion Completion block containing the captured UIImage
     */
    open func capturePictureWithCompletion(_ imageCompletion: @escaping (UIImage?, NSError?) -> Void) {
        self.capturePictureDataWithCompletion { data, error in
            
            guard error == nil, let imageData = data else {
                imageCompletion(nil, error)
                return
            }
            
            if self.savePhotosToUserLibrary == true, let library = self.library  {
                library.performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(data: imageData)!)
                }, completionHandler: { success, error in
                    guard error != nil else {
                        return
                    }
                    
                    DispatchQueue.main.async(execute: {
                        self.log(NSLocalizedString("Error", comment:""), message: (error?.localizedDescription)!)
                    })
                })
            }
            imageCompletion(UIImage(data: imageData), nil)
        }
    }
    
    /**
     Captures still image from currently running capture session.
     
     :param: imageCompletion Completion block containing the captured imageData
     */
    open func capturePictureDataWithCompletion(_ imageCompletion: @escaping (Data?, NSError?) -> Void) {
        
        guard cameraIsSetup else {
            log(NSLocalizedString("No capture session setup", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
            return
        }
        
        guard cameraOutputMode == .stillImage else {
            log(NSLocalizedString("Capture session output mode video", comment:""), message: NSLocalizedString("I can't take any picture", comment:""))
            return
        }
        
        sessionQueue.async(execute: {
            self._getStillImageOutput().captureStillImageAsynchronously(from: self._getStillImageOutput().connection(withMediaType: AVMediaTypeVideo), completionHandler: { [unowned self] sample, error in
                
                
                guard error == nil else {
                    DispatchQueue.main.async(execute: {
                        self.log(NSLocalizedString("Error", comment:""), message: (error?.localizedDescription)!)
                    })
                    imageCompletion(nil, error as NSError?)
                    return
                }
                
                let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(sample)
                
                
                imageCompletion(imageData, nil)
                
            })
        })
        
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension KMera: AVCaptureFileOutputRecordingDelegate {
    
    open func capture(_ captureOutput: AVCaptureFileOutput!, didStartRecordingToOutputFileAt fileURL: URL!, fromConnections connections: [Any]!) {
        
    }
    
    open func capture(_ captureOutput: AVCaptureFileOutput!, didFinishRecordingToOutputFileAt outputFileURL: URL!, fromConnections connections: [Any]!, error: Error!) {
        
        if (error != nil) {
            log(NSLocalizedString("Unable to save video to the iPhone", comment:""), message: error.localizedDescription)
        } else {
            
            if savePhotosToUserLibrary {
                
                if PHPhotoLibrary.authorizationStatus() == .authorized {
                    saveVideoToLibrary(outputFileURL)
                }
                else {
                    PHPhotoLibrary.requestAuthorization({ (autorizationStatus) in
                        if autorizationStatus == .authorized {
                            self.saveVideoToLibrary(outputFileURL)
                        }
                    })
                }
                
            } else {
                _executeVideoCompletionWithURL(outputFileURL, error: error as NSError?)
            }
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension KMera: UIGestureRecognizerDelegate {
    
    open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        
        if gestureRecognizer.isKind(of: UIPinchGestureRecognizer.self) {
            beginZoomScale = zoomScale;
        }
        
        return true
    }
    
    
    fileprivate func attachZoom(_ view: UIView) {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(KMera._zoomStart(_:)))
        view.addGestureRecognizer(pinch)
        pinch.delegate = self
    }
    
    
    
    @objc
    fileprivate func _zoomStart(_ recognizer: UIPinchGestureRecognizer) {
        guard let view = embeddingView, let previewLayer = previewLayer else {
            return
        }
        
        var allTouchesOnPreviewLayer = true
        let numTouch = recognizer.numberOfTouches
        
        for i in 0 ..< numTouch {
            let location = recognizer.location(ofTouch: i, in: view)
            let convertedTouch = previewLayer.convert(location, from: previewLayer.superlayer)
            if !previewLayer.contains(convertedTouch) {
                allTouchesOnPreviewLayer = false
                break
            }
        }
        if allTouchesOnPreviewLayer {
            applyZoom(recognizer.scale)
        }
    }
}
