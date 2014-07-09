$LOAD_PATH << File.join(File.dirname(__FILE__), '..', 'lib')
require 'simplecov'
SimpleCov.add_filter 'spec/' 
SimpleCov.start

require 'webmock/rspec'
require 'clicksend'