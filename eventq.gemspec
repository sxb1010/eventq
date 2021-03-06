# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
version = File.read(File.expand_path("EVENTQ_VERSION", __dir__)).strip

prerelease = ENV['TRAVIS_TAG'].scan(/rc\d*/)[0] if ENV['TRAVIS']

Gem::Specification.new do |spec|
  spec.name          = "eventq"
  spec.version       = version
  spec.version       = "#{spec.version}.#{prerelease}" if prerelease
  spec.authors       = ["SageOne"]
  spec.email         = ["sageone@sage.com"]

  spec.description = spec.summary = 'EventQ is a pub/sub system that uses async notifications and message queues'
  spec.homepage      = "https://github.com/sage/eventq"
  spec.license       = "MIT"

  spec.files         = ["README.md"] + Dir.glob("{bin,lib}/**/**/**")
  spec.require_paths = ["lib"]

  spec.add_development_dependency 'activesupport', '~> 4'
  spec.add_development_dependency 'bundler', '~> 1.11'
  spec.add_development_dependency 'byebug', '~> 11.0'
  spec.add_development_dependency 'pry-byebug', '~> 3.9'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'shoulda-matchers'
  spec.add_development_dependency 'simplecov'

  spec.add_dependency 'aws-sdk-sqs', '~> 1'
  spec.add_dependency 'aws-sdk-sns', '~> 1'
  spec.add_dependency 'bunny'
  spec.add_dependency 'class_kit'
  spec.add_dependency 'concurrent-ruby'
  spec.add_dependency 'oj'
  spec.add_dependency 'openssl'
  spec.add_dependency 'redlock'
end
