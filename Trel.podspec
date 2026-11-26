Pod::Spec.new do |s|
  s.name             = 'Trel'
  s.version          = '0.2.3'
  s.summary          = 'Crashes, app hangs, breadcrumbs, sessions, network spans and logs for iOS, sent to Trel over OTLP.'
  s.homepage         = 'https://trel.to'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Trel' => 'hello@trel.to' }
  # Published from the SPM mirror (git subtree of packages/sdk-ios); see README "Publishing".
  s.source           = { :git => 'https://github.com/waytodev/trel-ios.git', :tag => "v#{s.version}" }
  s.swift_version    = '5.9'

  # tvOS is supported through Swift Package Manager (Package.swift); the pod ships iOS + macOS.
  s.ios.deployment_target  = '15.0'
  s.osx.deployment_target  = '12.0'

  s.source_files = 'Sources/Trel/**/*.swift'
  s.resource_bundles = { 'Trel' => ['Sources/Trel/PrivacyInfo.xcprivacy'] }

  # 2.6.1 fixes __cxa_throw rebinding handing __DATA_CONST back read-only while dyld/objc still write it
  # (EXC_BAD_ACCESS in map_images on iOS 26.5 when a framework is dlopened, e.g. Metal during image decode).
  s.dependency 'KSCrash/Recording', '~> 2.6', '>= 2.6.1'
  s.frameworks = 'Foundation'
  s.ios.frameworks = 'UIKit'
end
