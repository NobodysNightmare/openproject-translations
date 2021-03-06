#encoding: utf-8
#
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2014 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.md for more details.
#++

require 'httmultiparty'
require 'rest_client'
require 'tempfile'
require 'yaml'
require 'zip'

namespace :translations do
  crowdin_project_key = ''
  crowdin_project_name = 'openproject'

  task :check_for_api_key => :environment do
    env_name = 'OPENPROJECT_CROWDIN_KEY'
    raise "ERROR: please specify a crowdin API key via the #{env_name} environment variable" unless ENV[env_name]
    crowdin_project_key = ENV[env_name]
  end

  desc "request a new build of the language export files"
  task :request_build => :check_for_api_key do
    response = JSON.parse RestClient.get("http://api.crowdin.net/api/project/#{crowdin_project_name}/export?json=&key=#{crowdin_project_key}")
    if response["success"]
      if response["success"]["status"] == "built"
        puts 'scheduled new build.'
      else
        puts 'already at latest version. skipped build.'
      end
    else
      puts 'Some error occured. either the crowdin-api changed, or the API key is not valid.'
    end
  end

  desc "fetch available translations from crowdin, and puts them into this gem"
  task :download => :check_for_api_key do
    unless File.writable? OpenProject::Translations::Engine.root.join 'config', 'locales'
      raise "#{OpenProject::Translations::Engine.root.join 'config', 'locales'} need to be writable"
    end

    puts 'Downloading translations from crowdin ...'
    response = RestClient.get("http://api.crowdin.net/api/project/#{crowdin_project_name}/download/all.zip?key=#{crowdin_project_key}")
    begin
      languages_files = Tempfile.new('crowdin_translations')
      languages_files.close
      File.open(languages_files.path, 'wb') do |file|
        file.write response
      end

      # read zip
      target_directory = OpenProject::Translations::Engine.root.join 'config', 'locales'
      Zip::File.open(languages_files.path) do |zip_file|
        zip_file.glob('**/*.yml').each do |entry|
          filename = entry.name.split('/').first + '.yml'
          filepath = target_directory.join filename
          puts "saving #{filename}"

          if File.file? filepath
            File.delete filepath
          end

          File.open(filepath, 'wb') do |file|
            file.write entry.get_input_stream.read
          end
        end
      end
    ensure
      languages_files.unlink
    end
  end

  desc "Upload current en.yml to crowdin, so that the crowd can update their translations"
  task :upload => :check_for_api_key do
    puts "Uploading current OpenProject en.yml to crowdin"
    path_to_upload_file = Rails.root.join 'config', 'locales', 'en.yml'
    response = RestClient.post("http://api.crowdin.net/api/project/#{crowdin_project_name}/update-file?key=#{crowdin_project_key}&update_option=update_without_changes&json=",
                             :'files[/en.yml]' => File.new(path_to_upload_file))
    puts response
  end

  desc "Insert missing translation keys into all translation files. This circumvents a crowdin bug."
  task :fix_missing_keys => :environment do
    # see: https://stackoverflow.com/questions/9381553/ruby-merge-nested-hash
    class ::Hash
      def deep_merge(second)
          merger = proc { |key, v1, v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
          self.merge(second, &merger)
      end
    end


    # read english translation keys from the openproject core
    english_translation = YAML.load File.read(Rails.root.join('config', 'locales', 'en.yml'))

    # fix missing translation keys in all translation files of this gem
    OpenProject::Translations::Engine.root.join('config', 'locales').children.select do |file_path|
      # find all .yml files in this gems' locales directory
      file_path.file? && file_path.to_s[-4..-1] == '.yml'
    end.each do |translation_file|
      # for each translation file add missing translation keys
      translation = YAML.load File.read(translation_file)
      # add missing english keys
      translation = {translation.keys.first => english_translation['en'].deep_merge(translation.values.first)}
      # write file bac kto disk
      File.open(translation_file, 'w') do |file|
        file.write translation.to_yaml
      end
    end
  end
end
