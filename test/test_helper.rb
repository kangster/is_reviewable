# coding: utf-8
require 'rubygems'

def smart_require(lib_name, gem_name, gem_version = '>= 0.0.0')
  begin
    require lib_name if lib_name
  rescue LoadError
    if gem_name
      gem gem_name, gem_version
      require lib_name if lib_name
    end
  end
end

# Explicitly load Rails 2.3
gem 'activerecord', '= 2.3.5'
require 'active_record'
gem 'activesupport', '= 2.3.5'
require 'active_support'

smart_require 'test/unit', 'test-unit', '= 1.2.3'
smart_require 'shoulda', 'shoulda', '>= 2.10.0'
# smart_require 'redgreen', 'redgreen', '>= 0.10.4'
smart_require 'sqlite3', 'sqlite3-ruby', '>= 1.2.0'
smart_require 'acts_as_fu', 'acts_as_fu', '>= 0.0.5'

require 'is_reviewable'

build_model :reviews do
  references  :reviewable,    :polymorphic => true
  
  references  :reviewer,      :polymorphic => true
  string      :ip,            :limit => 24
  
  float       :rating
  text        :body
  
  string      :title
  
  timestamps
end

build_model :guests
build_model :users
build_model :accounts
build_model :posts

build_model :reviewable_posts do
  is_reviewable :by => :users, :scale => 1.0..5.0, :step => 0.5, :average_precision => 2, :accept_ip => true, :review_class => Review
end

build_model :reviewable_articles do
  is_reviewable :by => [:accounts, :users], :scale => [1,2,3], :accept_ip => false, :review_class => Review
end

build_model :my_review do
  set_table_name :reviews
end

build_model :cached_reviewable_posts do
  is_reviewable :by => :users, :scale => 1..5, :total_precision => 2, :accept_ip => true, :review_class => MyReview

  integer :ratings_count, :default => 0
  integer :ratings_total, :default => 0
end