# coding: utf-8
require 'test_helper'

class IsReviewableTest < Test::Unit::TestCase
  
  def setup
    @review = ::Review.new
    
    @user = ::User.create
    @user_2 = ::User.create
    @user_3 = ::User.create
    @guest = ::Guest.create
    @account = ::Account.create
    
    @regular_post = ::Post.create
    @reviewable_post = ::ReviewablePost.create
    @reviewable_article = ::ReviewableArticle.create
    
    @cached_reviewable_post = ::CachedReviewablePost.create
    
    @anonymous_reviewable_post = ::AnonymousReviewablePost.create
  end
  
  context "initialization" do
    
    should "extend ActiveRecord::Base" do
       assert_respond_to ::ActiveRecord::Base, :is_reviewable
       assert_respond_to ::ActiveRecord::Base, :is_reviewable?
     end
     
     should "extend with instance methods only for reviewable models" do
       public_instance_methods = [
           [:is_reviewable?, :reviewable?],
           [:rating_scale, :reviewable_scale],
           [:rating_precision, :reviewable_precision],
           :reviewed_at,
           :average_rating,
           :average_rating_by,
           [:number_of_reviews, :total_reviews],
           [:is_reviewed?, :reviewed?],
           [:is_reviewed_by?, :reviewed_by?],
           :review_by,
           :review!,
           :unreview!,
           :reviews
         ].flatten
         
       assert public_instance_methods.all? { |m| @reviewable_post.respond_to?(m) }
       assert !public_instance_methods.all? { |m| @regular_post.respond_to?(m) }
     end
     
     should "be enabled only for specified models" do
       assert @reviewable_post.reviewable?
       assert @reviewable_article.reviewable?
       assert !@regular_post.reviewable?
     end
    
  end
  
  context "reviewable" do
    
    should "have many reviews" do
      assert @reviewable_post.respond_to?(:reviews)
      assert @reviewable_article.respond_to?(:reviews)
      
      @reviewable_post.review!(:by => @user, :rating => 2)
      @reviewable_post.review!(:by => @user_2, :rating => 2.5)
      
      assert_equal 2, @reviewable_post.reviews.size
    end
    
    should "have many reviewers" do
      assert @reviewable_post.respond_to?(:reviewers)
      assert @reviewable_article.respond_to?(:reviewers)
      
      @reviewable_post.review!(:by => @user, :rating => 2.5)
      @reviewable_post.review!(:by => @user_2, :rating => 2.5)
      @reviewable_post.review!(:by => @user_3, :rating => 2.5)
      
      assert_equal 3, @reviewable_post.reviewers.size
    end
    
    should "have no reviews from the beginning" do
      assert_equal(@reviewable_post.reviews.size, 0)
    end
    
    should "count reviews and ratings based on IP correctly" do
      @reviewable_post.review!(:by => '128.0.0.0', :rating => 1)
      @reviewable_post.review!(:by => '128.0.0.1', :rating => 2.5)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 1.75, @reviewable_post.average_rating # with precision set to 2
      
      # should not count as  new, but update values
      @reviewable_post.review!(:by => '128.0.0.1', :rating => 3)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 2.0, @reviewable_post.average_rating
      
      # should not count in the end
      @reviewable_post.review!(:by => '128.0.0.3', :rating => 1)
      @reviewable_post.unreview!(:by => '128.0.0.3', :rating => 1)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 2.0, @reviewable_post.average_rating
    end
    
    should "not accept any reviews on IP if disabled" do
      assert_raise ::IsReviewable::InvalidReviewerError do
        @reviewable_article.review!(:by => '128.0.0.0', :rating => 1)
      end
    end
    
    should "count reviews based on reviewer object (user/account) correctly" do
      @reviewable_post.review!(:by => @user, :rating => 1)
      @reviewable_post.review!(:by => @user_2, :rating => 2.5)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 1.75, @reviewable_post.average_rating # with precision set to 2
      
      # should not count as  new, but update values
      @reviewable_post.review!(:by => @user_2, :rating => 3)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 2.0, @reviewable_post.average_rating
      
      # should not count in the end
      @reviewable_post.review!(:by => @user_3, :rating => 1.0)
      @reviewable_post.unreview!(:by => @user_3, :rating => 1.0)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 2.0, @reviewable_post.average_rating
    end
    
    should "count reviews based on both IP and reviewer object (user/account) correctly" do
      @reviewable_post.review!(:by => @user, :rating => 1)
      @reviewable_post.review!(:by => '128.0.0.2', :rating => 2.5)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 1.75, @reviewable_post.average_rating # with precision set to 2
      
      # should not count as new, but update values
      @reviewable_post.review!(:by => '128.0.0.2', :rating => 3)
      
      assert_equal 2, @reviewable_post.total_reviews
      assert_equal 2.0, @reviewable_post.average_rating
    end
    
    should "not accept ratings out of rating scale range" do
      assert_raise ActiveRecord::RecordInvalid do
        @reviewable_post.review!(:by => @user, :rating => 6)
      end
    end
    
    should "save review body" do
      review_body = "Lorem ipsum dolor sit amet, consectetur adipisicing elit..."
      
      # just body
      review_1 = @reviewable_post.review!(:by => @user, :body => review_body)
      assert_equal(review_body, review_1.body)
      
      # body + rating
      review_2 = @reviewable_post.review!(:by => @user_2, :rating => 4, :body => review_body)
      assert_equal(review_body, review_2.body)
    end
    
    should "save any additional non-reserved attribute values" do
      review = @reviewable_post.review!(:by => @user, :rating => 4, :title => "My title")
      assert_equal "My title", review.title
      
      # don't allow update of reserved fields
      review = @reviewable_post.review!(:by => @user_2, :reviewable_id => 666)
      assert_not_equal 666, review.reviewable_id
    end
    
    should "remove the reviews when the parent reviewable object is destroyed" do
      reviewable_post = ::ReviewablePost.create
      
      review_1 = reviewable_post.review!(:by => @user_2, :rating => 4, :body => "hi")
      review_2 = reviewable_post.review!(:by => @user, :rating => 1, :body => "hello")
      
      reviewable_post.destroy
      assert_nil ::ReviewablePost.find_by_id(reviewable_post.id)
      assert_nil Review.find_by_id(review_1.id)
      assert_nil Review.find_by_id(review_2.id)
    end
    
    should "adjust the rating count and total when a review is destroyed" do
      review_1 = @cached_reviewable_post.review!(:by => @user_2, :rating => 4, :body => "hi")
      review_2 = @cached_reviewable_post.review!(:by => @user, :rating => 1, :body => "hello")
      review_3 = @cached_reviewable_post.review!(:by => "127.0.0.1", :rating => 5, :body => "what's up")
      review_4 = @cached_reviewable_post.review!(:by => "192.0.0.1", :rating => 2, :body => "wat up")
      
      @cached_reviewable_post.reload
      assert_equal 4, @cached_reviewable_post.ratings_count
      assert_equal 12, @cached_reviewable_post.ratings_total
      
      review_3.destroy
      @cached_reviewable_post.reload
      assert_equal 3, @cached_reviewable_post.ratings_count
      assert_equal 7, @cached_reviewable_post.ratings_total
    end
    
    should "calculate the average_rating with the cached fields" do
      review_1 = @cached_reviewable_post.review!(:by => @user_2, :rating => 5, :body => "hi")
      review_2 = @cached_reviewable_post.review!(:by => @user, :rating => 5, :body => "hello")
      review_3 = @cached_reviewable_post.review!(:by => "127.0.0.1", :rating => 3, :body => "what's up")
      
      @cached_reviewable_post.reload
      assert_equal 4.33, @cached_reviewable_post.average_rating
    end
    
  end
  
  context "reviewer" do
    
    should "have many reviews" do
       assert @user.respond_to?(:reviews)
       assert @account.respond_to?(:reviews)
       assert !@guest.respond_to?(:reviews)
       
       ReviewablePost.create.review!(:by => @user, :rating => 2.5)
       ReviewablePost.create.review!(:by => @user, :rating => 2.5)
       
       assert_equal 2, @user.reviews.size
     end
     
     should "have many reviewables" do
       assert @user.respond_to?(:reviewables)
       assert @account.respond_to?(:reviewables)
       assert !@guest.respond_to?(:reviewables)
       
       ReviewablePost.create.review!(:by => @user, :rating => 2.5)
       ReviewablePost.create.review!(:by => @user, :rating => 2.5)
       ReviewablePost.create.review!(:by => @user, :rating => 2.5)
       
       assert_equal 3, @user.reviewables.size
     end
    
  end
  
end