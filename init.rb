# Include hook code here
require 'responds_to_backport'

ActionController::Base.send :include, ActionController::MimeResponds
ActionController::Base.send :public, :render