# Requires in production.rb
# require 'data_mapper'
# require 'digest/sha2'

require 'dm-timestamps'

# Just log to STDOUT for now.
DataMapper::Logger.new($stdout, :debug)

include Trd

class User
  include DataMapper::Resource
  property :id,                 Serial, :key => true
  property :email,              String
  property :password,           String, :length => 256
  property :salt,               String
  property :verification_key,   String
  property :is_verified,        Boolean, :default => false
  property :type,               Discriminator
  property :created_at,         DateTime
  property :updated_at,         DateTime
  property :display,            Boolean, :default => true
end

class Student < User
  property :name,             String, :length => 256
  property :secondary_email,  String, :length => 256
  property :birthday,         Date
  property :school,           String, :length => 256
  property :major,            String, :length => 256
  property :minor,            String, :length => 256
  property :gpa,              Float
  property :interest1,        String
  property :interest2,        String
  property :interest3,        String
  property :class,            Date
  property :resume,           String
  property :photo,            String

  has n, :experiences
  has n, :extracurriculars
end

class Employer < User
  property :email,        String
  property :name,         String
  property :handle,       String
  property :url,          String, :length => 256
  property :founded,      Integer
  property :description,  String, :length => 1024
  property :handle,       String
  property :address,      String
  property :city,         String
  property :state,        String
  property :zipcode,      String
  property :phone,        String
  property :photo,        String
  property :account_id,   String
  property :plan,         String


  has n, :postings
end

class Experience
  include DataMapper::Resource

  belongs_to :student

  property :id,               Serial, :key => true
  property :position,         String
  property :place,            String
  property :desc,            String, :length => 1024
  property :start_date,       Date
  property :end_date,         Date
  property :deleted,          Boolean, :default => false
end

class Extracurricular
  include DataMapper::Resource

  belongs_to :student

  property :id,               Serial, :key => true
  property :position,         String
  property :place,            String
  property :desc,             String, :length => 1024
  property :start_date,       Date
  property :end_date,         Date
  property :deleted,          Boolean, :default => false
end

class Posting
  include DataMapper::Resource

  belongs_to :employer

  property :id,             Serial, :key => true
  property :position,       String
  property :place,          String
  property :description,    String
  property :start_date,     Date
  property :end_date,       Date
  property :deadline,       Date
  property :class,          String
  property :qualifications, String
  property :contact_name,   String
  property :contact_email,  String
  property :deleted,        Boolean, :default => false
end

class Subscription
  include DataMapper::Resource

  property :id, Serial
  property :charge_id, String
  property :employer_id, Integer
  property :is_processed, Boolean, :default => false
  property :is_recurring, Boolean, :default => false
end

# Create tables if they don't exist.
DataMapper.auto_upgrade!
DataMapper.finalize
