require 'rubygems'
require 'bundler/setup'
require 'sinatra'
require 'haml'
require 'stripe'
require 'pony'
require 'aws/s3'
require 'RMagick'
require 'will_paginate'
require 'will_paginate/data_mapper'

require 'csv'
require 'json'

# Helpers
require './lib/render_partial'
require File.expand_path('lib/production', File.dirname(__FILE__))
require File.expand_path('lib/exceptions', File.dirname(__FILE__))
require File.expand_path('lib/notifications', File.dirname(__FILE__))
require File.expand_path('lib/fixtures', File.dirname(__FILE__))
require File.expand_path('lib/models', File.dirname(__FILE__))

# Set Sinatra variables
set :app_file, __FILE__
set :root, File.dirname(__FILE__)
set :views, 'views'
set :public_folder, 'public'
set :haml, {:format => :html5} # default Haml format is :xhtml

# Sessions for login management
enable :sessions

include Trd

helpers do
  include Rack::Utils
  alias_method :h, :escape_html

  def  title(str = nil)
    # helper for formatting page title
    if str
      str + ' | MyGrad'
    else
      'MyGrad'
    end
  end

  def random_string(len)
    str = ''
    len.times do
      str << (i = Kernel.rand(62)
      i += ((i < 10) ? 48 : ((i < 36) ? 55 : 61 ))).chr
    end
    str
  end

  def hash(string, salt)
    Digest::SHA256.hexdigest("#{string}:#{salt}")
  end

  def validate(p, req)
    req.each { |r| raise TrdError.new("#{r.capitalize} field missing.") if p[r].nil? || p[r] == "" }
  end

  def numeric?(s)
    true if Float(s) rescue false
  end

  def nl2br(s)
        s.gsub(/\n/, '<br>')
  end

  def redirect_students()
    redirect '/' if @user.nil?
    raise Sinatra::NotFound unless (@user.type == Employer) || @user.is_admin
  end

  def all_interests()
    ['Advertising / PR', 'Consulting', 'Education', 'Entrepreneurship', 'Finance', 'Government / Military', 'Healthcare', 'Media / Entertainment', 'Non-Profit', 'Other', 'Real Estate', 'Technology']
  end

  def gen_paginate_html(results, cur_page, per_page = 50)
    html = "<div class='btn-toolbar'>"
      html+= "<div class='btn-group'>"
    total = results.length
    num_pages = (total/50).floor + 1
    if num_pages <= 5
      1.upto(num_pages) do |i|
        i == cur_page ? html+= "<a href='#' class='btn disabled'>#{i}</a>" : html += "<a href='#' class='btn'>#{i}</a>"
      end
    elsif num_pages > 5
      "<h1>More than 5 pages</h1>" 
    end
    html += "</div></div>"
    html
  end

def send_wb
  all = Student.all

  all.each do |u|
    u.email
    u.verification_key
    name = "there" # "Hi there"
    unless u.name.nil?
      name = u.name.split
      name = name[0]
    end
    Notifications.send_welcomeback_email(u.email, u.verification_key, name)
    puts "#{u.id} | #{u.name} | #{u.email}"
  end
end

def db
  users_csv = File.read('users.csv')
  info_csv = File.read('info.csv')
  users = CSV.parse(users_csv, :headers => true)
  info = CSV.parse(info_csv, :headers => true)

  users.each do |u|
    if u['Is_employer'] != "1"
      user = Student.first_or_create(:email => u['Email'])
      user.salt = random_string(6)
      user.verification_key = random_string(32)
      user.type = Student

      info.each do |row| 
        if row['UID'] == u['UID']
          user.name = "#{row['First']} #{row['Last']}" unless  row['First'].nil? || row['Last'].nil? || row['First'].empty? || row['Last'].empty?
          unless row['School'].nil? || row['School'].empty?
            user.school = row['School'] unless String.try_convert(row['School']).nil?
          end
          unless row['Major'].nil? || row['Major'].empty?
            if row['Major'].is_a? String
              user.major = row['Major']
            end
          end
          unless row['Minor'].nil? || row['Minor'].empty?
            if row['Minor'].is_a? String
              user.minor = row['Minor']
            end
          end
          unless row['GPA'].nil? || row['GPA'] == "0" || row['GPA'].empty?
            s = row['GPA'].to_f
            gpa = "%1.2f" % s
            user.gpa = gpa
          end
          unless row['Class'].nil? || row['Class'].empty? || row['Class'] == "0"
            user.class = Date.strptime(row['Class'], '%Y') rescue nil
          end
          user.is_verified = true;
        end
      end
      begin
        user.save
        puts "#{user.id} | #{user.email} | #{user.name}"
      rescue
        @error = user
        @users = Student.all
        haml :display_db
      end
    end
  end
  @users = Student.all
end

def upload_resumes
  users_csv = File.read('users.csv')
  info_csv = File.read('info.csv')
  users = CSV.parse(users_csv, :headers => true)
  info = CSV.parse(info_csv, :headers => true)

  users.each do |u|
    user = Student.first(:email => u['Email'])
    info.each do |i|
      if u['UID'] == i['UID']
        unless i['Resume'].nil? || i['Resume'].empty?
          old_resume_name = i['Resume'] 
          user.resume = "#{random_string(32)}.pdf"
          puts "USER: #{user.name}  |  OLD: #{old_resume_name}  |  NEW #{user.resume}"
          begin
            AWS::S3::Base.establish_connection!(
            :access_key_id     => ENV['AWS_ACCESS_KEY_ID'],
            :secret_access_key => ENV['AWS_SECRET_ACCESS_KEY'])
            if AWS::S3::S3Object.exists? old_resume_name, 'trdrop-assets'
              AWS::S3::S3Object.rename old_resume_name, user.resume, 'trdrop-assets', :access => :public_read
              user.save
            end
          rescue TrdError => e
            puts e
          end
        end
      end
    end
  end
end

def create_trial_employer(email, name)
  begin
    @user = Employer.first(:email => email)
    raise TrdError.new("Looks like that email is already registered.") unless @user.nil?

    salt = random_string(6)
    hash = hash("foobar", salt)

    verification_key = random_string(32)

    # Create profile and send email
    user = Employer.create(:email => email, :password => hash, :salt => salt, :verification_key => verification_key, :name => name)
    # Notifications.send_verification_email(user.email, user.verification_key)

    #bypass normal registration stuff
    user.display = false
    user.is_verified = true
    user.save

    puts "You've successfully registered. Check your email for a verification email."
  rescue TrdError => e
    puts e.message
  end
end

end #end helpers

before do
  @success = nil

  # preserve session error, else reset
  unless session[:error].nil?
    @error = session[:error]
    session[:error] = nil
  else
    @error = nil
  end

  user_id = session[:user]
  @user = User.get(user_id)
end

before '/profile' do
  if @user.type == Student
    @experiences = Experience.all(:student_id => @user.id, :deleted.not => 'true', :order => [ :end_date.desc ])
    @extracurriculars = Extracurricular.all(:student_id => @user.id, :deleted.not => 'true', :order => [ :end_date.desc ])
    @interests = all_interests
  else
    @postings = Posting.all(:employer_id => @user.id, :deadline.gt => Time.now, :deleted.not => 'true', :order => [ :deadline.asc ])
  end
end

get '/' do
  @title = title 'Welcome'
  redirect '/profile' unless @user.nil?
  haml :index, :layout => :'layouts/index'
end

post '/' do
  begin
    validate(params, [:name, :password, :email])

    unless params[:email].end_with? ".edu"
      raise TrdError.new("Sorry, only students can register with MyGrad. If you are an employer, please see our <a href='/pricing'>pricing page</a>.")
    end

    @user = Student.first(:email => params[:email])
    raise TrdError.new("Looks like that email is already registered.") unless @user.nil?

    salt = random_string(6)
    hash = hash(params[:password], salt)

    verification_key = random_string(32)

    # Create profile and send email
    user = Student.create(:email => params[:email], :password => hash, :salt => salt, :verification_key => verification_key, :name => params[:name], :email => params[:email])
    Notifications.send_verification_email(user.email, user.verification_key)

    @success = "You've successfully registered. Check your email for a verification email."

    haml :index, :layout => :'layouts/index'
  rescue TrdError => e
    @error = e.message
    @success = nil
    haml :index, :layout => :'layouts/index'
  end
end

post '/upload/:action' do
  begin
    unless params['file'] && (tmpfile = params['file'][:tempfile]) && (name = params['file'][:filename])
        redirect '/profile' unless @user.nil?
    end

    # generate name and determine filetype
    ext = File.extname(params['file'][:filename])
    name = "#{random_string(32)}#{ext}"
    # ENV['RACK_ENV'] == 'production' ? tmpname = "#{RAILS_ROOT}/tmp/#{name}" : tmpname=name

    case params[:action]
    when 'photo'
      # unless ext.eql?('.jpg') or ext.eql?('.png') or ext.eql?('.gif') or ext.eql?('.jpeg')
      #     raise e = TrdError.new("Profile images must be of type .jpg, .png, or .gif")
      # end
        #connect to s3
        AWS::S3::Base.establish_connection!(
        :access_key_id     => settings.s3_key,
        :secret_access_key => settings.s3_secret)

        #resize image before storing
        begin
          img = Magick::Image.read(params['file'][:tempfile].path).first
        rescue
          raise e = TrdError.new("File must be an image.")
        end

        @user.type == Student ? img.resize_to_fill(300,300).write(name) : img.resize_to_fit(300).write(name)

      begin
        #store it
        AWS::S3::S3Object.store(name,open(name),settings.bucket,:access => :public_read)     
        File.delete(name) unless ENV['RACK_ENV'] == 'production'
      rescue
        raise e = TrdError.new("Upload failed. Please try again.")
      end
      # if successful, set user as profile image
      @user.update(:photo => name) 
      
      # send result to ajax
      @user.photo

    when 'resume'
      unless ext.eql?('.pdf')
        raise e = TrdError.new("Resumes must be of type .pdf") 
      end
      begin
        AWS::S3::Base.establish_connection!(
        :access_key_id     => settings.s3_key,
        :secret_access_key => settings.s3_secret)
        AWS::S3::S3Object.store(name,open(tmpfile),settings.bucket,:access => :public_read)     
      rescue
        raise TrdError.new("Upload to S3 failed.")
      end
      # if successful, set user as profile image
      @user.update(:resume=> name) 

      # send result to ajax
      @user.resume
    end

  rescue TrdError => e
    @error = e.message
    @success = nil
    if @user.type == Student
      session[:error] = e.message
      redirect '/profile'
    else
      haml :employer_profile, :layout => :'layouts/application'
    end
  end
end

get '/verify/:key' do
  @title = title 'Verify'
  begin
    redirect '/profile' unless @user.nil?
    e = TrdError.new("Invalid verification key.")
    raise e if params[:key].nil?
    user = nil

    user = User.first(:verification_key => params[:key])

    raise e if user.nil?
    raise e if user.verification_key != params[:key]

    if user.type == Student
      user.update(:is_verified => true)
      @success = "You have successfully verified your account. You can now <a href='/'>log in</a>."
    else
      Stripe.api_key = settings.stripe_key
      c = Stripe::Customer.retrieve(user.account_id)
      c.update_subscription(:plan => user.plan)

      user.update(:is_verified => true)
      @success = "You have successfully verified your account and your account has been charged. You can now <a href='/'>log in</a>."
    end

    haml :verify, :layout => :'layouts/message'
  rescue Stripe::StripeError
    @error = "We were unable to process your payment. Please email support@mygrad.com.au for more information."
    @success = nil
    haml :verify, :layout => :'layouts/message'
  rescue TrdError => e
    @error = e.message
    @success = nil
    haml :verify, :layout => :'layouts/message'
  end
end

get '/profile' do
  @title = title @user.name
  redirect '/' if @user.nil?
  if @user.type == Employer
    haml :employer_profile, :layout => :'layouts/application'
  else
    haml :student_profile, :layout => :'layouts/application'
  end
end

post '/profile' do
  @interests = all_interests
  redirect '/' if @user.nil?
  begin
    student_actions = %w{personal work education extracurricular}
    employer_actions = %w{about posting}


    if @user.type == Student
      unless student_actions.include? params[:action]
          raise TrdError.new("Sorry, an error occured.")
      end
      case params[:action]
      when "education"
        params[:school].empty? || params[:school].nil? ? @user.school = nil : @user.school = params[:school]
        params[:major].empty? || params[:major].nil? ? @user.major = nil : @user.major = params[:major]
        params[:minor].empty? || params[:minor].nil? ? @user.minor = nil : @user.minor = params[:minor]

        if params[:class].nil? || params[:class].empty?
          @user.class = nil
        elsif not numeric?(params[:class])
          raise TrdError.new("Your class year must be a numeric date (YYYY).")
        else
          begin
            @user.class = Date.strptime(params[:class], "%Y")
          rescue
            raise TrdError.new("Your class year must be a valid date (YYYY).")
          end
        end

        if params[:gpa].nil? || params[:gpa].empty?
          @user.gpa = nil
        elsif not numeric?(params[:gpa])
          raise TrdError.new("Your GPA must be a number.")
        else
            params[:gpa].length > 3 ? @user.gpa = "%1.2f" % params[:gpa] : @user.gpa = "%1.1f" % params[:gpa]
        end

        # @user.update(:school => params[:school], :major => params[:major], :minor => params[:minor], :class => class_year, :gpa => gpa)
        @user.save
      
      when "personal"
        # make sure interests are valid
        [:interest1, :interest2, :interest3].each do |i|
          unless (params[i] == "") || (all_interests.include? params[i])
            raise TrdError.new("Invalid interest selection: #{params[i]}. Please try again.")
          end
        end
        # updatasaurus
        if params[:secondary_email].empty? || params[:secondary_email].nil?
          @user.update(:interest1 => params[:interest1], :interest2 => params[:interest2], :interest3 => params[:interest3])
        else
          @user.update(:secondary_email => params[:secondary_email], :interest1 => params[:interest1], :interest2 => params[:interest2], :interest3 => params[:interest3])
        end
        
      when "work"
        [:position, :place, :start_date, :end_date, :desc].each do |i|
          raise TrdError.new("Please enter all the fields.") if params[i].nil? || params[i] == ""
        end
        work = @user.experiences.new
        work.position = params[:position]
        work.place = params[:place]
        begin
          work.start_date = Date.strptime(params[:start_date], "%m/%Y")
          work.end_date = Date.strptime(params[:end_date], "%m/%Y")
        rescue
          raise TrdError.new("Invalid date (MM/YYYY required).")
        end
        work.desc = params[:desc]
        work.save
        @user.save
        
      when "extracurricular"
        puts "Hello, extracurriculars!"
        [:position, :place, :start_date, :end_date, :desc].each do |i|
          raise TrdError.new("Please enter all the fields.") if params[i].nil? || params[i] == ""
        end
        exp = @user.extracurriculars.new
        exp.position = params[:position]
        exp.place = params[:place]
        begin
          exp.start_date = Date.strptime(params[:start_date], "%m/%Y")
          exp.end_date = Date.strptime(params[:end_date], "%m/%Y")
        rescue
          raise TrdError.new("Invalid date (MM/YYYY required).")
        end
        exp.desc = params[:desc]
        exp.save
        @user.save
      end

      haml :student_profile, :layout => :'layouts/application'
      
    else
      unless employer_actions.include? params[:action]
          raise TrdError.new("Sorry, an error occured.")
      end
      case params[:action]
      when "about"
        params[:description].nil? || params[:description].empty? ? @user.description = nil : @user.description = nl2br(params[:description])
        params[:address].nil? || params[:address].empty? ? @user.address = nil : @user.address = params[:address]
        params[:city].nil? || params[:city].empty? ? @user.city = nil : @user.city = params[:city]
        params[:state].nil? || params[:state].empty? ? @user.state = nil : @user.state = params[:state]
        params[:zipcode].nil? || params[:zipcode].empty? ? @user.zipcode = nil : @user.zipcode = params[:zipcode]
        @user.save

      when "posting"
        [:position, :place, :start_date, :end_date, :description, :class, :qualifications, :contact_name, :contact_email].each do |i|
          raise TrdError.new("Please enter all the fields.") if params[i].nil? || params[i].empty?
        end
        posting = @user.postings.new
        posting.position = params[:position]
        posting.place = params[:place]
        posting.description = params[:description]
        posting.class = params[:class]
        posting.qualifications = params[:qualifications]
        posting.contact_name = params[:contact_name]
        posting.contact_email = params[:contact_email]
        begin
          posting.deadline = Date.strptime(params[:deadline], "%d/%m/%Y")
          posting.start_date= Date.strptime(params[:start_date], "%d/%m/%Y")
          posting.end_date = Date.strptime(params[:end_date], "%d/%m/%Y")
        rescue
          raise TrdError.new("Invalid date (DD/MM/YYYY required).")
        end
        posting.deadline = params[:deadline]
        posting.save
        @user.save
      end
      
      haml :employer_profile, :layout => :'layouts/application'
    end
  rescue TrdError => e
    @error= e.message
    @success = nil
    if @user.type == Student
      @experiences = Experience.all(:student_id => @user.id, :deleted.not => 'true', :order => [ :end_date.desc ])
      @extracurriculars = Extracurricular.all(:student_id => @user.id, :deleted.not => 'true', :order => [ :end_date.desc ])
      haml :student_profile, :layout => :'layouts/application'
    else
      @postings = Posting.all(:employer_id => @user.id, :deadline.gt => Time.now, :deleted.not => 'true', :order => [ :deadline.asc ])
      haml :employer_profile, :layout => :'layouts/application'
    end
  end
end

get '/profile/:id' do
  redirect '/' if @user.nil?

  @profile_user = User.get(params[:id])
  redirect '/profile' if @user.id == params[:id].to_i

  if @user.type == Employer
    @student = Student.get(params[:id].to_i)
    raise TrdError.new("Sorry, this page does not exist.") if @student.nil?

    @experiences = Experience.all(:student_id => @student.id, :deleted.not => 'true', :order => [ :end_date.desc ])
    @extracurriculars = Extracurricular.all(:student_id => @student.id, :deleted.not => 'true', :order => [ :end_date.desc ])
    @title = title @student.name
    haml :other_student_profile, :layout => :'layouts/application'
  else
    @employer = Employer.first(:handle=> params[:id])
    raise TrdError.new("Sorry, this page does not exist.") if @employer.nil?

    @postings = Posting.all(:employer_id => @employer.id, :deadline.gt => Time.now, :deleted.not => 'true', :order => [ :deadline.asc ])
    @title = title @employer.name
    haml :other_employer_profile, :layout => :'layouts/application'
  end
end

get '/profile/delete/:type/:id' do
  begin
    case params[:type]
    when 'experience'
      o = Experience.get(params[:id])
      raise TrdError.new("We could not process that request.") unless o.student_id == @user.id
      o.update(:deleted => true)
    when 'extracurricular'
      o = Extracurricular.get(params[:id], )
      raise TrdError.new("We could not process that request.") unless o.student_id == @user.id
      o.update(:deleted => true)
    when 'posting'
      o = Posting.get(params[:id])
      raise TrdError.new("We could not process that request.") unless o.employer_id == @user.id
      o.update(:deleted => true)
    end
    redirect '/profile'
  rescue TrdError => e
    @error = e.message
    haml :error, :layout => :'layouts/message'
  end
end

post '/login' do
  begin
    redirect '/profile' unless @user.nil?
    validate(params, [:email, :password])
    user = User.first(:email => params[:email])

    # make sure email is valid
    raise e = TrdError.new("Oops.") if user.nil?

    # check password
    pass = hash(params[:password], user.salt)
    raise e = TrdError.new("Nope.") if pass != user.password

    # make sure user is verified
    raise e = TrdError.new("Nope.") unless user.is_verified

    # insert info into sessions
    session[:user] = user.id
    redirect '/profile'
  rescue TrdError => e
    @error = "Something went wrong while trying to log you in. Please try again."
    @success = nil
    haml :login, :layout => :'layouts/panel'
  end
end

get '/fixtures' do
  Fixtures.generate
end

get '/logout' do
  session.clear
  redirect '/'
end

get '/employers' do
  @title = title 'Employers'
  begin
    employers = Employer.all(:is_verified => true, :type => Employer)
    raise TrdError.new("Sorry, we have no companies listed.") if employers.length.zero?
    @employers = employers
    haml :employers, :layout => :'layouts/application'
  rescue TrdError => e
    @error = e.message
    @success = nil
    haml :employers, :layout => :'layouts/application'
  end
end

get '/jobs' do
  @title = title 'Jobs'
  begin
    postings = Posting.all(:deadline.gt => Time.now, :deleted.not => 'true', :order => [ :deadline.asc ])
    raise TrdError.new("Sorry, we have no jobs listed currently.") if postings.length.zero?
    @postings = postings 
    haml :jobs, :layout => :'layouts/application'
  rescue TrdError => e
    @error = e.message
    @success = nil
    haml :jobs, :layout => :'layouts/application'
  end
end

get '/pricing' do
  @title = title 'Pricing'
  haml :pricing, :layout => :'layouts/application'
end

get '/subscribe' do
  redirect '/pricing'
end

get '/subscribe/:plan' do
  @title = title 'Subscribe'
  haml :subscribe, :layout => :'layouts/subscribe'
end

post '/subscribe/:plan' do
  begin
    validate(params, [:token, :email, :name, :password, :handle, :url, :phone])
    user = User.get(:email => params[:email])
    raise TrdError.new("This account is already registered. Please contact us at support@mygrad.com.au to delete this account.") unless user.nil?

    Stripe.api_key = settings.stripe_key
    customer = Stripe::Customer.create(
      :description => "Customer for #{params[:name]}",
      :email => params[:email],
      :card => params[:token]
    )

    salt = random_string(6)
    hash = hash(params[:password], salt)

    verification_key = random_string(32)

    Employer.create(:email => params[:email], :password => hash, :salt => salt, :verification_key => verification_key, :name => params[:name], :email => params[:email], :phone => params[:phone], :account_id => customer.id, :plan => params[:plan], :handle => params[:handle], :url => params[:url])
    Notifications.send_verification_email(params[:email], verification_key)

    @success = "You've successfully registered. Please wait to hear back from us to verify your account."

    haml :subscribe, :layout => :'layouts/subscribe'
  rescue TrdError => e
    @error = e.message
    @success = nil
    haml :subscribe, :layout => :'layouts/subscribe'
  rescue Stripe::StripeError
    @error = "We were unable to process your payment. Please email support@mygrad.com.au for more information."
    @success = nil
    haml :subscribe, :layout => :'layouts/subscribe'
  end
end

post '/stripe/webhook' do
  Stripe.api_key = settings.stripe_key

  # Retrieve the request's body and parse it as JSON
  event_json = JSON.parse(request.body.read)

  if event_json['type'] == 'charge.succeeded'
    begin
      customer = Employer.first(:account_id => event_json['data']['object']['customer'])
    rescue
      email = "support@mygrad.com.au"
    end

    if customer.nil?
      to = 'ssansovich@gmail.com'
      date = Time.at(event_json['data']['object']['created'])
      date = date.strftime('%B %e, %Y')
      amount = '%.2f' % (event_json['data']['object']['amount'] / 100.0 )
      plan = 'Something went wrong'
      Notifications.send_dump(event_json)
    else
      to = customer.email
      plan = customer.plan
      date = Time.at(event_json['created'])
      date = date.strftime('%B %e, %Y')
      amount = '%.2f' % (event_json['data']['object']['amount'] / 100.0 )
    end

    Notifications.send_payment_receipt(to, date, amount, plan)
  end
end


# Static pages.

get '/about' do
  @title = title 'About'
  haml :about, :layout => :'layouts/application'
end

get '/privacy' do
  @title = title 'Privacy'
  haml :privacy, :layout => :'layouts/application'
end

get '/terms' do
  @title = title 'Terms'
  haml :terms, :layout => :'layouts/application'
end

not_found do
  @error = "The page you requested was not found."
  haml :error, :layout => :'layouts/message'
end

error do
  haml :error, :layout => :'layouts/message'
end

get '/search' do
  @interests = all_interests
  @title = title 'Search'
  begin
    if @user.type == Employer
      if params.empty?
        haml :search, :layout => :'layouts/application'
      else
        
        # Generate query string. I know this sucks. Bear with me.
        @results = Student.all( :is_verified => true, :display => true)
        @results = @results.all(:conditions => ["name ILIKE ?", "%#{params[:name]}%"]) unless params[:name].empty?
        @results = @results.all(:conditions => ["school ILIKE ?", "%#{params[:school]}%"]) unless params[:school].empty?
        @results = @results.all(:conditions => ["class = ?", "%#{DateTime.strptime(params[:class],'%Y')}%"]) unless params[:class].empty?
        @results = @results.all(:gpa.gte => params[:gpa]) unless params[:gpa].empty?
        @results = @results.all(:conditions => ["major ILIKE ?", "%#{params[:major]}%"]) unless params[:major].empty?
        @results = @results.all(:conditions => ["minor ILIKE ?", "%#{params[:minor]}%"]) unless params[:minor].empty?
        # @results = @results.all(:conditions => ["interest1 ILIKE ?", "%#{params[:interest]}%"]) unless params[:interest1] == ""

        @results = @results.paginate(:page => params[:page], :per_page => 30)

        # if no results found, show error.
        raise TrdError.new("Sorry, we couldn't find anything with the parameters you specified.") if @results.nil? || @results.empty?
        haml :search, :layout => :'layouts/application'
      end
    else
      redirect '/profile'
    end
  rescue TrdError => e
      @error = e.message
      haml :search, :layout => :'layouts/application'
  end
end

post '/contact' do
  @user.nil? ? email = params[:email] : email = @user.email
  message = params[:body]
  Notifications.send_contact_email(email, message)
end

get '/welcomeback/:key' do
  @title = title 'Welcome back!'
  begin
    redirect '/profile' unless @user.nil?

    @user = User.first(:verification_key => params[:key])
    raise nil if @user.nil?

    haml :welcomeback, :layout => :'layouts/panel'
  rescue
    @error = "Invalid verification key."
    @success = nil
    haml :error, :layout => :'layouts/message'
  end
end

post '/welcomeback/:key' do
  begin
    @user = User.first(:verification_key => params[:key])
    raise nil if @user.nil?
    raise nil if @user.type == Employer
    
    e = validate(params, [:name, :password, :password2])

    if params[:password].eql? params[:password2]
      pass = hash(params[:password], @user.salt)
      #reset verification key to invalidate link
      v_key = random_string(32)
      @user.update({:is_verified => true, :password => pass, :name => params[:name], :verification_key => v_key})
    else
      raise e = TrdError.new("Passwords do not match.")
    end

    @success = "You can now <a href='/'>log in</a>."
    @error = nil
    haml :welcomeback, :layout => :'layouts/panel'
  rescue TrdError => e
    @success = nil
    @error = e.message
    haml :welcomeback, :layout => :'layouts/panel'
  rescue
    @error = "Please try again."
    haml :error, :layout => :'layouts/message'
  end
end

get '/forgotpassword' do
  haml :forgotpassword, :layout => :'layouts/panel'
end

post '/forgotpassword' do
  @user = User.first(:email => params[:email])
  puts params[:email]
  unless @user.nil?
    Notifications.send_password_recovery(@user.email,@user.verification_key,@user.name)
    @success = "Please check your email for a link to reset your password."
  else
    @message = "That email does not appear to be in our database. Please try again."
  end
  haml :forgotpassword, :layout => :'layouts/panel'
end

get '/passwordreset/:k' do
  @title = title 'Password Reset'
  begin
    @user = User.first(:verification_key => params[:k])
    raise nil if @user.nil?
  rescue
    @error = "That is an invalid URL. If you pasted the URL from an email, please make sure you copied the entire link."
    haml :error, :layout => :'layouts/message'
  end

  @k = params[:k]
  haml :passwordreset, :layout => :'layouts/panel'
end

post '/passwordreset/:k' do
  begin
    @user = User.first(:verification_key => params[:k])
    raise "That is an invalid URL." if @user.nil?

    raise p = TrdError.new("Those passwords do not match. Please try again") unless params[:pass1] == params[:pass2]
    @user.password = hash(params[:pass1], @user.salt)
    @user.save
    @success = "Your password has been changed. You can now log in at the <a href='http://www.mygrad.com.au'>homepage</a>."

    haml :passwordreset, :layout => :"layouts/panel"
  rescue TrdError => p
    @success = nil
    @message = p.message
    haml :passwordreset, :layout => :"layouts/panel"
  rescue Exception => e
    @error = e.message
    haml :error, :layout => :'layouts/message'
  end
end
