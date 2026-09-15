Pod::Spec.new do |s|
  s.name             = 'Trel'
  s.version          = '0.1.0'
  s.summary          = 'Crashes, app hangs, breadcrumbs, sessions, network spans and logs for iOS, sent to Trel over OTLP.'
  s.homepage         = 'https://trel.to'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Trel' => 'hello@trel.to' }
  # Published from the SPM mirror (git subtree of packages/sdk-ios); see README "Publishing".
  s.source           = { :git => 'https://github.com/waytodev/trel-ios.git', :tag => "v#{s.version}" }
  s.swift_version    = '5.9'

  # tvOS is supported through Swift Package Manager (Package.swift); the pod ships iOS + macOS.
  s.ios.deployment_target  = '13.0'
  s.osx.deployment_target  = '10.15'

  s.source_files = 'Sources/Trel/**/*.swift'
  s.resource_bundles = { 'Trel' => ['Sources/Trel/PrivacyInfo.xcprivacy'] }

  s.dependency 'KSCrash/Recording', '~> 2.0'
  s.frameworks = 'Foundation'
  s.ios.frameworks = 'UIKit'
end
