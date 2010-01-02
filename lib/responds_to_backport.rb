module ActionController #:nodoc:
  
  
  class Request
    def negotiate_mime(order)
      formats.each do |priority|
        if priority == Mime::ALL
          return order.first
        elsif order.include?(priority)
          return priority
        end
      end

      order.include?(Mime::ALL) ? formats.first : nil
    end
    
    def format(view_path = [])
      formats.first
    end

    def formats
      accept = @env['HTTP_ACCEPT']

      @env["action_dispatch.request.formats"] ||=
        if parameters[:format]
          Array.wrap(Mime::Type.lookup(parameters[:format]))
        elsif xhr? || (accept && !accept.include?(?,))
          accepts
        else
          [Mime::HTML]
        end
    end
    
    def format=(extension)
      parameters[:format] = extension.to_s
      @env["action_dispatch.request.formats"] = [Mime::Type.lookup_by_extension(parameters[:format])]
    end
    
  end
  
  # Responder is responsible to expose a resource for different mime requests,
  # usually depending on the HTTP verb. The responder is triggered when
  # respond_with is called. The simplest case to study is a GET request:
  #
  #   class PeopleController < ApplicationController
  #     respond_to :html, :xml, :json
  #
  #     def index
  #       @people = Person.find(:all)
  #       respond_with(@people)
  #     end
  #   end
  #
  # When a request comes, for example with format :xml, three steps happen:
  #
  #   1) responder searches for a template at people/index.xml;
  #
  #   2) if the template is not available, it will invoke :to_xml in the given resource;
  #
  #   3) if the responder does not respond_to :to_xml, call :to_format on it.
  #
  # === Builtin HTTP verb semantics
  #
  # Rails default responder holds semantics for each HTTP verb. Depending on the
  # content type, verb and the resource status, it will behave differently.
  #
  # Using Rails default responder, a POST request for creating an object could
  # be written as:
  #
  #   def create
  #     @user = User.new(params[:user])
  #     flash[:notice] = 'User was successfully created.' if @user.save
  #     respond_with(@user)
  #   end
  #
  # Which is exactly the same as:
  #
  #   def create
  #     @user = User.new(params[:user])
  #
  #     respond_to do |format|
  #       if @user.save
  #         flash[:notice] = 'User was successfully created.'
  #         format.html { redirect_to(@user) }
  #         format.xml { render :xml => @user, :status => :created, :location => @user }
  #       else
  #         format.html { render :action => "new" }
  #         format.xml { render :xml => @user.errors, :status => :unprocessable_entity }
  #       end
  #     end
  #   end
  #
  # The same happens for PUT and DELETE requests.
  #
  # === Nested resources
  #
  # You can given nested resource as you do in form_for and polymorphic_url.
  # Consider the project has many tasks example. The create action for
  # TasksController would be like:
  #
  #   def create
  #     @project = Project.find(params[:project_id])
  #     @task = @project.comments.build(params[:task])
  #     flash[:notice] = 'Task was successfully created.' if @task.save
  #     respond_with(@project, @task)
  #   end
  #
  # Giving an array of resources, you ensure that the responder will redirect to
  # project_task_url instead of task_url.
  #
  # Namespaced and singleton resources requires a symbol to be given, as in
  # polymorphic urls. If a project has one manager which has many tasks, it
  # should be invoked as:
  #
  #   respond_with(@project, :manager, @task)
  #
  # Check polymorphic_url documentation for more examples.
  #
  class Responder
    attr_reader :controller, :request, :format, :resource, :resources, :options

    ACTIONS_FOR_VERBS = {
      :post => :new,
      :put => :edit
    }

    def initialize(controller, resources, options={})
      @controller = controller
      @request = controller.request
      @format = controller.formats.first
      @resource = resources.is_a?(Array) ? resources.last : resources
      @resources = resources
      @options = options
      @action = options.delete(:action)
      @default_response = options.delete(:default_response)
    end

    delegate :head, :render, :redirect_to,   :to => :controller
    delegate :get?, :post?, :put?, :delete?, :to => :request

    # Undefine :to_json and :to_yaml since it's defined on Object
    undef_method(:to_json) if method_defined?(:to_json)
    undef_method(:to_yaml) if method_defined?(:to_yaml)

    # Initializes a new responder an invoke the proper format. If the format is
    # not defined, call to_format.
    #
    def self.call(*args)
      new(*args).respond
    end

    # Main entry point for responder responsible to dispatch to the proper format.
    #
    def respond
      method = :"to_#{format}"
      respond_to?(method) ? send(method) : to_format
    end

    # HTML format does not render the resource, it always attempt to render a
    # template.
    #
    def to_html
      default_render
    rescue ActionView::MissingTemplate => e
      navigation_behavior(e)
    end

    # All others formats follow the procedure below. First we try to render a
    # template, if the template is not available, we verify if the resource
    # responds to :to_format and display it.
    #
    def to_format
      default_render
    rescue ActionView::MissingTemplate => e
      raise unless resourceful?
      api_behavior(e)
    end

  protected

    # This is the common behavior for "navigation" requests, like :html, :iphone and so forth.
    def navigation_behavior(error)
      if get?
        raise error
      elsif has_errors? && default_action
        render :action => default_action
      else
        redirect_to resource_location
      end
    end

    # This is the common behavior for "API" requests, like :xml and :json.
    def api_behavior(error)
      if get?
        display resource
      elsif has_errors?
        display resource.errors, :status => :unprocessable_entity
      elsif post?
        display resource, :status => :created, :location => resource_location
      else
        head :ok
      end
    end

    # Checks whether the resource responds to the current format or not.
    #
    def resourceful?
      resource.respond_to?(:"to_#{format}")
    end

    # Returns the resource location by retrieving it from the options or
    # returning the resources array.
    #
    def resource_location
      options[:location] || resources
    end

    # If a given response block was given, use it, otherwise call render on
    # controller.
    #
    def default_render
      @default_response.call
    end

    # display is just a shortcut to render a resource with the current format.
    #
    #   display @user, :status => :ok
    #
    # For xml request is equivalent to:
    #
    #   render :xml => @user, :status => :ok
    #
    # Options sent by the user are also used:
    #
    #   respond_with(@user, :status => :created)
    #   display(@user, :status => :ok)
    #
    # Results in:
    #
    #   render :xml => @user, :status => :created
    #
    def display(resource, given_options={})
      controller.render given_options.merge!(options).merge!(format => resource)
    end

    # Check if the resource has errors or not.
    #
    def has_errors?
      resource.respond_to?(:errors) && !resource.errors.empty?
    end

    # By default, render the :edit action for html requests with failure, unless
    # the verb is post.
    #
    def default_action
      @action ||= ACTIONS_FOR_VERBS[request.method]
    end
  end
end


# RespondsToBackport
module ActionController #:nodoc:
  module MimeResponds #:nodoc:
    #extend ActiveSupport::Concern

    def self.included(base)
      base.extend(ClassMethods)
      #instance_eval do
      #  write_inheritable_attribute(:responder, ActionController::Responder)
      #end
      base.class_eval do
        class_inheritable_accessor :responder
        class_inheritable_accessor :mimes_for_respond_to#, :instance_writer => false
        attr_accessor :formats
        self.responder = ActionController::Responder
        #clear_respond_to
      end
      base.clear_respond_to
    end

    module ClassMethods
      # Defines mimes that are rendered by default when invoking respond_with.
      #
      # Examples:
      #
      #   respond_to :html, :xml, :json
      #
      # All actions on your controller will respond to :html, :xml and :json.
      #
      # But if you want to specify it based on your actions, you can use only and
      # except:
      #
      #   respond_to :html
      #   respond_to :xml, :json, :except => [ :edit ]
      #
      # The definition above explicits that all actions respond to :html. And all
      # actions except :edit respond to :xml and :json.
      #
      # You can specify also only parameters:
      #
      #   respond_to :rjs, :only => :create
      #
      def respond_to(*mimes)
        options = mimes.extract_options!

        only_actions   = Array(options.delete(:only))
        except_actions = Array(options.delete(:except))

        mimes.each do |mime|
          mime = mime.to_sym
          mimes_for_respond_to[mime]          = {}
          mimes_for_respond_to[mime][:only]   = only_actions   unless only_actions.empty?
          mimes_for_respond_to[mime][:except] = except_actions unless except_actions.empty?
        end
      end

      # Clear all mimes in respond_to.
      #
      def clear_respond_to
        self.mimes_for_respond_to = ActiveSupport::OrderedHash.new
      end
    end

    # Without web-service support, an action which collects the data for displaying a list of people
    # might look something like this:
    #
    #   def index
    #     @people = Person.find(:all)
    #   end
    #
    # Here's the same action, with web-service support baked in:
    #
    #   def index
    #     @people = Person.find(:all)
    #
    #     respond_to do |format|
    #       format.html
    #       format.xml { render :xml => @people.to_xml }
    #     end
    #   end
    #
    # What that says is, "if the client wants HTML in response to this action, just respond as we
    # would have before, but if the client wants XML, return them the list of people in XML format."
    # (Rails determines the desired response format from the HTTP Accept header submitted by the client.)
    #
    # Supposing you have an action that adds a new person, optionally creating their company
    # (by name) if it does not already exist, without web-services, it might look like this:
    #
    #   def create
    #     @company = Company.find_or_create_by_name(params[:company][:name])
    #     @person  = @company.people.create(params[:person])
    #
    #     redirect_to(person_list_url)
    #   end
    #
    # Here's the same action, with web-service support baked in:
    #
    #   def create
    #     company  = params[:person].delete(:company)
    #     @company = Company.find_or_create_by_name(company[:name])
    #     @person  = @company.people.create(params[:person])
    #
    #     respond_to do |format|
    #       format.html { redirect_to(person_list_url) }
    #       format.js
    #       format.xml  { render :xml => @person.to_xml(:include => @company) }
    #     end
    #   end
    #
    # If the client wants HTML, we just redirect them back to the person list. If they want Javascript
    # (format.js), then it is an RJS request and we render the RJS template associated with this action.
    # Lastly, if the client wants XML, we render the created person as XML, but with a twist: we also
    # include the person's company in the rendered XML, so you get something like this:
    #
    #   <person>
    #     <id>...</id>
    #     ...
    #     <company>
    #       <id>...</id>
    #       <name>...</name>
    #       ...
    #     </company>
    #   </person>
    #
    # Note, however, the extra bit at the top of that action:
    #
    #   company  = params[:person].delete(:company)
    #   @company = Company.find_or_create_by_name(company[:name])
    #
    # This is because the incoming XML document (if a web-service request is in process) can only contain a
    # single root-node. So, we have to rearrange things so that the request looks like this (url-encoded):
    #
    #   person[name]=...&person[company][name]=...&...
    #
    # And, like this (xml-encoded):
    #
    #   <person>
    #     <name>...</name>
    #     <company>
    #       <name>...</name>
    #     </company>
    #   </person>
    #
    # In other words, we make the request so that it operates on a single entity's person. Then, in the action,
    # we extract the company data from the request, find or create the company, and then create the new person
    # with the remaining data.
    #
    # Note that you can define your own XML parameter parser which would allow you to describe multiple entities
    # in a single request (i.e., by wrapping them all in a single root node), but if you just go with the flow
    # and accept Rails' defaults, life will be much easier.
    #
    # If you need to use a MIME type which isn't supported by default, you can register your own handlers in
    # environment.rb as follows.
    #
    #   Mime::Type.register "image/jpg", :jpg
    #
    # Respond to also allows you to specify a common block for different formats by using any:
    #
    #   def index
    #     @people = Person.find(:all)
    #
    #     respond_to do |format|
    #       format.html
    #       format.any(:xml, :json) { render request.format.to_sym => @people }
    #     end
    #   end
    #
    # In the example above, if the format is xml, it will render:
    #
    #   render :xml => @people
    #
    # Or if the format is json:
    #
    #   render :json => @people
    #
    # Since this is a common pattern, you can use the class method respond_to
    # with the respond_with method to have the same results:
    #
    #   class PeopleController < ApplicationController
    #     respond_to :html, :xml, :json
    #
    #     def index
    #       @people = Person.find(:all)
    #       respond_with(@person)
    #     end
    #   end
    #
    # Be sure to check respond_with and respond_to documentation for more examples.
    #
    def respond_to(*mimes, &block)
      raise ArgumentError, "respond_to takes either types or a block, never both" if mimes.any? && block_given?

      if response = retrieve_response_from_mimes(mimes, &block)
        response.call
      end
    end

    # respond_with wraps a resource around a responder for default representation.
    # First it invokes respond_to, if a response cannot be found (ie. no block
    # for the request was given and template was not available), it instantiates
    # an ActionController::Responder with the controller and resource.
    #
    # ==== Example
    #
    #   def index
    #     @users = User.all
    #     respond_with(@users)
    #   end
    #
    # It also accepts a block to be given. It's used to overwrite a default
    # response:
    #
    #   def destroy
    #     @user = User.find(params[:id])
    #     flash[:notice] = "User was successfully created." if @user.save
    #
    #     respond_with(@user) do |format|
    #       format.html { render }
    #     end
    #   end
    #
    # All options given to respond_with are sent to the underlying responder,
    # except for the option :responder itself. Since the responder interface
    # is quite simple (it just needs to respond to call), you can even give
    # a proc to it.
    #
    def respond_with(*resources, &block)
      if response = retrieve_response_from_mimes([], &block)
        options = resources.extract_options!
        options.merge!(:default_response => response)
        (options.delete(:responder) || responder).call(self, resources, options)
      end
    end

  protected

    # Collect mimes declared in the class method respond_to valid for the
    # current action.
    #
    def collect_mimes_from_class_level #:nodoc:
      action = action_name.to_sym

      mimes_for_respond_to.keys.select do |mime|
        config = mimes_for_respond_to[mime]

        if config[:except]
          !config[:except].include?(action)
        elsif config[:only]
          config[:only].include?(action)
        else
          true
        end
      end
    end

    # Collects mimes and return the response for the negotiated format. Returns
    # nil if :not_acceptable was sent to the client.
    #
    def retrieve_response_from_mimes(mimes, &block)
      collector = Collector.new { default_render }
      mimes = collect_mimes_from_class_level if mimes.empty?
      mimes.each { |mime| collector.send(mime) }
      block.call(collector) if block_given?

      if format = request.negotiate_mime(collector.order)
        self.formats = [format.to_sym]
        collector.response_for(format)
      else
        head :not_acceptable
        nil
      end
    end

    class Collector #:nodoc:
      attr_accessor :order

      def initialize(&block)
        @order, @responses, @default_response = [], {}, block
      end

      def any(*args, &block)
        if args.any?
          args.each { |type| send(type, &block) }
        else
          custom(Mime::ALL, &block)
        end
      end
      alias :all :any

      def custom(mime_type, &block)
        mime_type = mime_type.is_a?(Mime::Type) ? mime_type : Mime::Type.lookup(mime_type.to_s)
        @order << mime_type
        @responses[mime_type] ||= block
      end

      def response_for(mime)
        @responses[mime] || @responses[Mime::ALL] || @default_response
      end

      def self.generate_method_for_mime(mime)
        sym = mime.is_a?(Symbol) ? mime : mime.to_sym
        const = sym.to_s.upcase
        class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{sym}(&block)                # def html(&block)
            custom(Mime::#{const}, &block)  #   custom(Mime::HTML, &block)
          end                               # end
        RUBY
      end

      Mime::SET.each do |mime|
        generate_method_for_mime(mime)
      end

      def method_missing(symbol, &block)
        mime_constant = Mime.const_get(symbol.to_s.upcase)

        if Mime::SET.include?(mime_constant)
          self.class.generate_method_for_mime(mime_constant)
          send(symbol, &block)
        else
          super
        end
      end

    end
  end
end
