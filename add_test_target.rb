#!/usr/bin/env ruby
# Adds a LexoraTests unit-test target to Lexora.xcodeproj
require 'xcodeproj'

PROJECT_PATH = File.expand_path('Lexora.xcodeproj', __dir__)
TEST_DIR     = File.expand_path('LexoraTests',      __dir__)
BUNDLE_ID    = 'com.yiga.LexoraTests'
TEAM_ID      = '7AZTZL9VAG'

project    = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'Lexora' }

abort "Could not find Lexora target" unless app_target

# Skip if test target already exists
if project.targets.any? { |t| t.name == 'LexoraTests' }
  puts "LexoraTests target already exists — nothing to do."
  exit 0
end

# ── Create test target ────────────────────────────────────────────────────────
test_target = project.new_target(
  :unit_test_bundle,
  'LexoraTests',
  :ios,
  '17.0',
  project.products_group,
  :swift
)

# ── Link against Lexora host app ──────────────────────────────────────────────
test_target.add_dependency(app_target)

# ── Add LexoraTests group & source file ──────────────────────────────────────
tests_group = project.main_group.new_group('LexoraTests', 'LexoraTests')
test_file   = tests_group.new_file('LexoraTests.swift')
test_target.source_build_phase.add_file_reference(test_file)

# ── Build settings ────────────────────────────────────────────────────────────
[project.build_configuration_list, test_target.build_configuration_list].each do |_|; end

test_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'BUNDLE_LOADER'              => '$(TEST_HOST)',
    'TEST_HOST'                  => '$(BUILT_PRODUCTS_DIR)/Lexora.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Lexora',
    'PRODUCT_BUNDLE_IDENTIFIER'  => BUNDLE_ID,
    'SWIFT_VERSION'              => '5.0',
    'IPHONEOS_DEPLOYMENT_TARGET' => '17.0',
    'DEVELOPMENT_TEAM'           => TEAM_ID,
    'CODE_SIGN_STYLE'            => 'Automatic',
    'ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES' => 'YES',
  )
end

project.save
puts "✅ LexoraTests target added to #{PROJECT_PATH}"
