# coding: utf-8

module IsReviewable
  module Reviewable
    ASSOCIATION_CLASS = ::IsReviewable::Review
    CACHABLE_FIELDS = [
        :ratings_total,
        :ratings_count
      ].freeze
    DEFAULTS = {
        :accept_ip => false,
        :scale => 1..5 
      }.freeze
      
    def self.included(base) #:nodoc:
      base.class_eval do
        extend ClassMethods
      end
      
      # Checks if this object reviewable or not.
      #
      def reviewable?; false; end
      alias :is_reviewable? :reviewable?
    end
    
    module ClassMethods
      
      # TODO: Document this method...thoroughly.
      #
      # Examples:
      #
      #   is_reviewable :by => :user, :scale => 0..5, :total_precision => 2
      #
      def is_reviewable(*args)
        options = args.extract_options!
        options.reverse_merge!(
            :by         => nil,
            :scale      => options[:values] || options[:range] || DEFAULTS[:scale],
            :accept_ip  => options[:anonymous] || DEFAULTS[:accept_ip] # i.e. also accepts unique IPs as reviewer
          )
        scale = options[:scale]
        if options[:step].blank? && options[:steps].blank?
          options[:steps] = scale.last - scale.first + 1
        else
          # use :step or :steps beneath
        end
        options[:total_precision] ||= options[:average_precision] || scale.first.to_s.split('.').last.size # == 1
        
        # Check for incorrect input values, and handle ranges of floats with help of :step. E.g. :scale => 1.0..5.0.
        
        if scale.is_a?(::Range) && scale.first.is_a?(::Float)
          options[:step] = (scale.last - scale.first) / (options[:steps] - 1) if options[:step].blank?
          options[:scale] = scale.first.step(scale.last, options[:step]).collect { |value| value }
        else
          options[:scale] = scale.to_a.collect! { |v| v.to_f }
        end
        raise InvalidConfigValueError, ":scale/:range/:values must consist of numeric values only." unless options[:scale].all? { |v| v.is_a?(::Numeric) }
        raise InvalidConfigValueError, ":total_precision must be an integer." unless options[:total_precision].is_a?(::Fixnum)
        
        # Assocations: Review class (e.g. Review).
        options[:review_class] ||= ASSOCIATION_CLASS
        
        # Had to do this here - not sure why. Subclassing Review should be enough? =S
        options[:review_class].class_eval do
          # Increment count and add to total
          after_create do |record|
            if record.reviewable && record.reviewable.reviewable_caching_fields?
              reviewable = record.reviewable.tap do |r|
                r.ratings_total += record.rating.to_i
                r.ratings_count += 1
              end
              reviewable.save_without_validation
            end
          end
          
          # Decrement count and subtract from total
          before_destroy do |record|
            if record.reviewable(true) && record.reviewable.reviewable_caching_fields?
              reviewable = record.reviewable.tap do |r|
                r.ratings_total -= record.rating.to_i
                r.ratings_count -= 1
              end
              reviewable.save_without_validation
            end
          end
          
          belongs_to :reviewable, :polymorphic => true unless self.respond_to?(:reviewable)
          belongs_to :reviewer,   :polymorphic => true unless self.respond_to?(:reviewer)
          
          validate do |review|
            if review.rating && review.reviewable
              review.errors.add(:rating, "must be a valid value in the specified scale") unless review.reviewable.class.rating_scale.include?(review.rating)
            end
          end
        end
        
        # Reviewer class(es).
        options[:reviewer_classes] = [*options[:by]].compact.collect do |class_name|
          begin
            class_name.to_s.singularize.classify.constantize
          rescue NameError => e
            raise InvalidReviewerError, "Reviewer class #{class_name} not defined, needs to be defined. #{e}"
          end
        end
        
        # Assocations: Reviewer class(es) (e.g. User, Account, ...).
        options[:reviewer_classes].each do |reviewer_class|
          if ::Object.const_defined?(reviewer_class.name.to_sym)
            reviewer_class.class_eval do
              #has_many  :reviews, :as => :reviewer, :dependent  => :delete_all
              has_many :reviews,
                :foreign_key => :reviewer_id,
                :class_name => options[:review_class].name
              # Polymorphic has-many-through not supported (has_many :reviewables, :through => :reviews), so:
              # TODO: Implement with :join
              def reviewables(*args)
                query_options = args.extract_options!
                query_options[:include] = [:reviewable]
                query_options.reverse_merge!(:conditions => Support.polymorphic_conditions_for(self, :reviewer))
                
                ::Review.find(:all, query_options).collect! { |review| review.reviewable }
              end
            end
          end
        end
        
        # Assocations: Reviewable class (self) (e.g. Page).
        self.class_eval do
          has_many :reviews, :as => :reviewable, :dependent => :delete_all, :class_name => options[:review_class].name
          
          # Polymorphic has-many-through not supported (has_many :reviewers, :through => :reviews), so:
          # TODO: Implement with :join
          def reviewers(*args)
            query_options = args.extract_options!
            query_options[:include] = [:reviewer]
            query_options.reverse_merge!(:conditions => Support.polymorphic_conditions_for(self, :reviewable))
            
            ::Review.find(:all, query_options).collect! { |review| review.reviewer }
          end
          
          before_create :init_reviewable_caching_fields
          
          include ::IsReviewable::Reviewable::InstanceMethods
          extend  ::IsReviewable::Reviewable::Finders
        end
        
        # Save the initialized options for this class.
        self.write_inheritable_attribute :is_reviewable_options, options
        self.class_inheritable_reader :is_reviewable_options
      end
      
      # Checks if this object reviewable or not.
      #
      def reviewable?
        @@reviewable ||= self.respond_to?(:is_reviewable_options, true)
      end
      alias :is_reviewable? :reviewable?
      
      # The rating scale used for this reviewable class.
      #
      def reviewable_scale
        self.is_reviewable_options[:scale]
      end
      alias :rating_scale :reviewable_scale
      
      # The rating value precision used for this reviewable class.
      #
      # Using Rails default behaviour:
      #
      #   Float#round(<precision>)
      #
      def reviewable_precision
        self.is_reviewable_options[:total_precision]
      end
      alias :rating_precision :reviewable_precision
      
      protected
        
        # Check if the requested reviewer object is a valid reviewer.
        #
        def validate_reviewer(identifiers)
          raise InvalidReviewerError, "Argument can't be nil: no reviewer object or IP provided." if identifiers.blank?
          reviewer = identifiers[:by] || identifiers[:reviewer] || identifiers[:user] || identifiers[:ip]
          is_ip = Support.is_ip?(reviewer)
          reviewer = reviewer.to_s.strip if is_ip
          
          unless Support.is_active_record?(reviewer) || is_ip
            raise InvalidReviewerError, "Reviewer is of wrong type: #{reviewer.inspect}."
          end
          raise InvalidReviewerError, "Reviewing based on IP is disabled." if is_ip && !self.is_reviewable_options[:accept_ip]
          reviewer
        end
        
    end
    
    module InstanceMethods
      
      # Checks if this object reviewable or not.
      #
      def reviewable?
        self.class.reviewable?
      end
      alias :is_reviewable? :reviewable?
      
      # The rating scale used for this reviewable class.
      #
      def reviewable_scale
        self.class.reviewable_scale
      end
      alias :rating_scale :reviewable_scale
      
      # The rating value precision used for this reviewable class.
      #
      def reviewable_precision
        self.class.reviewable_precision
      end
      alias :rating_precision :reviewable_precision
      
      # Reviewed at datetime.
      #
      def reviewed_at
        self.created_at if self.respond_to?(:created_at)
      end
      
      # Calculate average rating for this reviewable object.
      # 
      def average_rating(recalculate = false)
        if !recalculate && self.reviewable_caching_fields?
          (self.ratings_total.to_f / self.ratings_count.to_f).round(reviewable_precision)
        else
          conditions = self.reviewable_conditions(true)
          conditions[0] << ' AND rating IS NOT NULL'
          ::Review.average(:rating,
            :conditions => conditions).to_f.round(self.is_reviewable_options[:total_precision])
        end
      end
      
      # Calculate average rating for this reviewable object within a domain of reviewers.
      #
      def average_rating_by(identifiers)
        # FIXME: Only count non-nil ratings, i.e. See "average_rating".
        ::Review.average(:rating,
            :conditions => self.reviewer_conditions(identifiers).merge(self.reviewable_conditions)
          ).to_f.round(self.is_reviewable_options[:total_precision])
      end
      
      # Get the total number of reviews for this object.
      #
      def total_reviews(recalculate = false)
        if !recalculate && self.reviewable_caching_fields?
          self.ratings_total
        else
          ::Review.count(:conditions => self.reviewable_conditions)
        end
      end
      alias :number_of_reviews :total_reviews
      
      # Is this object reviewed by anyone?
      #
      def reviewed?
        self.total_reviews > 0
      end
      alias :is_reviewed? :reviewed?
      
      # Check if an item was already reviewed by the given reviewer or ip.
      #
      # === identifiers hash:
      # * <tt>:ip</tt> - identify with IP
      # * <tt>:reviewer/:user/:account</tt> - identify with a reviewer-model (e.g. User, ...)
      #
      def reviewed_by?(identifiers)
        self.reviews.exists?(:conditions => reviewer_conditions(identifiers))
      end
      alias :is_reviewed_by? :reviewed_by?
      
      # Get review already reviewed by the given reviewer or ip.
      #
      def review_by(identifiers)
        self.reviews.find(:first, :conditions => reviewer_conditions(identifiers))
      end
      
      # View the object with and identifier (user or ip) - create new if new reviewer.
      #
      # === identifiers_and_options hash:
      # * <tt>:reviewer/:user/:account</tt> - identify with a reviewer-model or IP (e.g. User, Account, ..., "128.0.0.1")
      # * <tt>:rating</tt> - Review rating value, e.g. 3.5, "3.5", ... (optional)
      # * <tt>:body</tt> - Review text body, e.g. "Lorem *ipsum*..." (optional)
      # * <tt>:*</tt> - Any custom review field, e.g. :reviewer_mood => "angry" (optional)
      #
      def review!(identifiers_and_options)
        review = build_review(identifiers_and_options)
        review.save!
        review
      end
      
      def build_review(identifiers_and_options)
        # Except for the reserved fields, any Review-fields should be be able to update.
        review_values = identifiers_and_options.except(*::IsReviewable::Review::ASSOCIATIVE_FIELDS)
        
        reviewer = self.validate_reviewer(identifiers_and_options)
        review = self.review_by(identifiers_and_options)
        
        if review
          review.attributes = review_values.slice(*review.attribute_names.collect { |an| an.to_sym })
        else
          review = self.reviews.build do |r|
            r.attributes = review_values.slice(*r.attribute_names.collect { |an| an.to_sym })
          
            if Support.is_active_record?(reviewer)
              r.reviewer_id   = reviewer.id
              r.reviewer_type = reviewer.class.name
            else
              r.ip = reviewer
            end
          end
        end
        
        review
      end
      
      # Remove the review of this reviewer from this object.
      #
      def unreview!(identifiers)
        review = self.review_by(identifiers)
        review_rating = review.rating if review.present?
        
        if review && review.destroy
          self.update_cache!
        else
          raise RecordError, "Could not un-review #{review.inspect} by #{reviewer.inspect}: #{e}"
        end
      end
      
      protected
        
        # Update cache fields if available/enabled.
        #
        def update_cache!
          if self.reviewable_caching_fields?(:total_reviews)
            # self.cached_total_reviews += 1 if review.new_record?
            self.cached_total_reviews = self.total_reviews(true)
          end
          if self.reviewable_caching_fields?(:average_rating)
            # new_rating = review.rating - (old_rating || 0)
            # self.cached_average_rating = (self.cached_average_rating + new_rating) / self.cached_total_reviews.to_f
            self.cached_average_rating = self.average_rating(true)
          end
          self.save_without_validation if self.changed?
        end
        
        # Cachable fields for this reviewable class.
        #
        def reviewable_caching_fields
          CACHABLE_FIELDS
        end
        
        # Checks if there are any cached fields for this reviewable class.
        #
        def reviewable_caching_fields?(*fields)
          fields = CACHABLE_FIELDS if fields.blank?
          fields.all? { |field| self.attributes.with_indifferent_access.has_key?(:"#{field}") }
        end
        alias :has_reviewable_caching_fields? :reviewable_caching_fields?
        
        # Initialize any cached fields.
        #
        def init_reviewable_caching_fields
          self.cached_total_reviews = 0 if self.reviewable_caching_fields?(:cached_total_reviews)
          self.cached_average_rating = 0.0 if self.reviewable_caching_fields?(:average_rating)
        end
        
        def reviewable_conditions(as_array = false)
          conditions = {:reviewable_id => self.id, :reviewable_type => self.class.name}
          as_array ? Support.hash_conditions_as_array(conditions) : conditions
        end
        
        # Generate query conditions.
        #
        def reviewer_conditions(identifiers, as_array = false)
          reviewer = self.validate_reviewer(identifiers)
          if Support.is_active_record?(reviewer)
            conditions = {:reviewer_id => reviewer.id, :reviewer_type => reviewer.class.name}
          else
            conditions = {:ip => reviewer.to_s}
          end
          as_array ? Support.hash_conditions_as_array(conditions) : conditions
        end
        
        def validate_reviewer(identifiers)
          self.class.send(:validate_reviewer, identifiers)
        end
        
    end
    
    module Finders
      
      # TODO: Finders
      # 
      # * users that reviewed this with rating X
      # * users that reviewed this, also reviewed [...] with same rating
      
    end
    
  end
end

# Extend ActiveRecord.
::ActiveRecord::Base.class_eval do
  include ::IsReviewable::Reviewable
end
