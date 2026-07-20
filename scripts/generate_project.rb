#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"

root = File.expand_path("..", __dir__)
project_path = File.join(root, "ColdShot.xcodeproj")

existing_team = nil
if File.directory?(project_path)
  existing_project = Xcodeproj::Project.open(project_path)
  existing_target = existing_project.targets.find { |target| target.name == "ColdShot" }
  existing_team = existing_target&.build_configurations
    &.map { |configuration| configuration.build_settings["DEVELOPMENT_TEAM"] }
    &.find { |team| team && !team.empty? }
end

development_team = ENV["DEVELOPMENT_TEAM"] || existing_team
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2650"
project.root_object.attributes["LastUpgradeCheck"] = "2650"

core_target = project.new_target(:framework, "ColdShotCore", :osx, "15.0")
app_target = project.new_target(:application, "ColdShot", :osx, "15.0")
app_target.add_dependency(core_target)
app_target.frameworks_build_phase.add_file_reference(core_target.product_reference)
embed_frameworks = app_target.new_copy_files_build_phase("Embed Frameworks")
embed_frameworks.dst_subfolder_spec = "10"
embedded_core = embed_frameworks.add_file_reference(core_target.product_reference, true)
embedded_core.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
app_target.add_system_frameworks(["Photos", "AppKit"])

core_group = project.main_group.new_group("ColdShotCore", "ColdShotCore")
core_sources_group = core_group.new_group("Sources", "Sources/ColdShotCore")
Dir.glob(File.join(root, "ColdShotCore/Sources/ColdShotCore/*.swift")).sort.each do |path|
  reference = core_sources_group.new_file(path)
  core_target.source_build_phase.add_file_reference(reference)
end

app_group = project.main_group.new_group("ColdShotApp", "ColdShotApp")
Dir.glob(File.join(root, "ColdShotApp/*.swift")).sort.each do |path|
  reference = app_group.new_file(path)
  app_target.source_build_phase.add_file_reference(reference)
end
app_group.new_file(File.join(root, "ColdShotApp/Info.plist"))
app_group.new_file(File.join(root, "ColdShotApp/ColdShot.entitlements"))

project.build_configurations.each do |configuration|
  configuration.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
end

core_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.coldshot.core"
  settings["PRODUCT_NAME"] = "ColdShotCore"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["MARKETING_VERSION"] = "0.1"
  settings["OTHER_LDFLAGS"] = "$(inherited) -lsqlite3"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["DEFINES_MODULE"] = "YES"
  settings["SKIP_INSTALL"] = "YES"
  settings["SWIFT_VERSION"] = "6.0"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["CODE_SIGNING_ALLOWED"] = "NO"
end

app_target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.coldshot.prototype"
  settings["PRODUCT_NAME"] = "ColdShot"
  settings["INFOPLIST_FILE"] = "ColdShotApp/Info.plist"
  settings["CODE_SIGN_ENTITLEMENTS"] = "ColdShotApp/ColdShot.entitlements"
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  settings["SWIFT_VERSION"] = "6.0"
  settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  settings["ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"] = "YES"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  if development_team && !development_team.empty?
    settings["DEVELOPMENT_TEAM"] = development_team
    settings["CODE_SIGN_IDENTITY"] = "Apple Development"
  end
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.set_launch_target(app_target)
scheme.save_as(project_path, "ColdShot", true)

puts "Generated #{project_path}"
