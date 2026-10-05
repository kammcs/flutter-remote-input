#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint remote_input.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'remote_input'
  s.version          = '0.0.1'
  s.summary          = 'Replays a remote viewer\'s keyboard and mouse input on this Mac.'
  s.description      = <<-DESC
Replays a remote viewer's keyboard and mouse input on this Mac (CGEventPost),
with the Accessibility permission checks. See the package's docs/design.md.
                       DESC
  s.homepage         = 'https://github.com/kammcs/flutter-remote-input'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Kamm Creative Solutions' => 'https://github.com/kammcs' }

  s.source           = { :path => '.' }
  s.source_files = 'remote_input/Sources/remote_input/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'remote_input_privacy' => ['remote_input/Sources/remote_input/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
