require_relative 'module'

require 'fastlane_core/build_watcher'
require 'fastlane_core/ipa_file_analyser'
require 'fastlane_core/pkg_file_analyser'

module Deliver
  class SubmitForReview
    def submit!(options)
      legacy_app = options[:app]
      app_id = legacy_app.apple_id
      app = Spaceship::ConnectAPI::App.get(app_id: app_id)

      platform = Spaceship::ConnectAPI::Platform.map(options[:platform])
      version = app.get_edit_app_store_version(platform: platform)

      unless version
        UI.user_error!("Cannot submit for review - could not find an editable version for '#{platform}'")
        return
      end

      build = select_build(options, app, version, platform)

      update_export_compliance(options, app, build)
      update_idfa(options, app, version)
      update_submission_information(options, app)

      version.create_app_store_version_submission

      UI.success("Successfully submitted the app for review!")
    end

    private def select_build(options, app, version, platform)
      if options[:build_number] && options[:build_number] != "latest"
        UI.message("Selecting existing build-number: #{options[:build_number]}")

        build = Spaceship::ConnectAPI::Build.all(
          app_id: app.id,
          version: options[:app_version],
          build_number: options[:build_number],
          platform: platform
        ).first

        unless build
          UI.user_error!("Build number: #{options[:build_number]} does not exist")
        end
      else
        UI.message("Selecting the latest build...")
        build = wait_for_build_processing_to_be_complete(app: app, platform: platform, options: options)
      end
      UI.message("Selecting build #{build.app_version} (#{build.version})...")

      version.select_build(build_id: build.id)

      UI.success("Successfully selected build")

      return build
    end

    def update_export_compliance(options, app, build)
      submission_information = options[:submission_information] || {}
      uses_encryption = submission_information[:export_compliance_uses_encryption]

      UI.verbose("Updating build for export compliance status of '#{uses_encryption}'")
      if build.uses_non_exempt_encryption.nil?
        build = build.update(attributes: {
          usesNonExemptEncryption: uses_encryption
        })
      end
      UI.verbose("Updated build for export compliance status of '#{build.uses_non_exempt_encryption}'")
    end

    def update_idfa(options, app, version)
      submission_information = options[:submission_information] || {}
      return unless submission_information.include?(:add_id_info_uses_idfa)

      uses_idfa = submission_information[:add_id_info_uses_idfa]
      idfa_declaration = begin
                           version.fetch_idfa_declaration
                         rescue
                           nil
                         end

      UI.verbose("Updating app store version for IDFA status of '#{uses_idfa}'")
      version = version.update(attributes: {
        usesIdfa: uses_idfa
      })
      UI.verbose("Updated app store version for IDFA status of '#{version.uses_idfa}'")

      if uses_idfa == false
        if idfa_declaration
          UI.verbose("Deleting IDFA delcaration")
          idfa_declaration.delete!
          UI.verbose("Deleted IDFA delcaration")
        end
      end

      UI.success("Successfully updated IDFA delcarations")
    end

    def update_submission_information(options, app)
      submission_information = options[:submission_information] || {}
      if submission_information.include?(:content_rights_contains_third_party_content)
        value = if submission_information[:content_rights_contains_third_party_content]
                  Spaceship::ConnectAPI::App::ContentRightsDeclaration::USES_THIRD_PARTY_CONTENT
                else
                  Spaceship::ConnectAPI::App::ContentRightsDeclaration::DOES_NOT_USE_THIRD_PARTY_CONTENT
                end

        UI.success("Updating contents rights declaration on App Store Connect")
        app.update(attributes: {
          contentRightsDeclaration: value
        })
      end
    end

    def wait_for_build_processing_to_be_complete(app: nil, platform: nil, options: nil)
      app_version = options[:app_version]
      app_version ||= FastlaneCore::IpaFileAnalyser.fetch_app_version(options[:ipa]) if options[:ipa]
      app_version ||= FastlaneCore::PkgFileAnalyser.fetch_app_version(options[:pkg]) if options[:pkg]

      app_build ||= FastlaneCore::IpaFileAnalyser.fetch_app_build(options[:ipa]) if options[:ipa]
      app_build ||= FastlaneCore::PkgFileAnalyser.fetch_app_build(options[:pkg]) if options[:pkg]

      latest_build = FastlaneCore::BuildWatcher.wait_for_build_processing_to_be_complete(
        app_id: app.id,
        platform: platform,
        app_version: app_version,
        build_version: app_build,
        poll_interval: 15,
        return_when_build_appears: false,
        return_spaceship_testflight_build: false
      )

      unless latest_build.app_version == app_version && latest_build.version == app_build
        UI.important("Uploaded app #{app_version} - #{app_build}, but received build #{latest_build.app_version} - #{latest_build.version}.")
      end

      return latest_build
    end
  end
end
