NewBooks::Application.routes.draw do
  Blacklight.add_routes(self)
  
  root :to => "search#index"
 
  match 'search/', :to => "search#index", :as => :search_index

  devise_for :users

  match 'backend/holdings/:id' => 'backend#holdings', :as => 'backend_holdings'

  match 'lweb', :to => 'search#index', :as => :lweb_search, :defaults => {:categories => ['lweb']}
  match 'articles', :to => "articles#index"
  match 'articles/show', :to => "articles#show", :as => :article_show
  match 'articles/search', :to => "articles#search", :as => :article_search
  match 'ebooks', :to => 'search#ebooks', :as => :search_ebooks
  match 'backend/clio_recall/:id', :to => "backend#clio_recall" , :as => :clio_recall
  match 'locations/show/:id', :id => /[^\/]+/, :to => "locations#show", :as => :location_display
  match 'backend/feedback_mail', :to => "backend#feedback_mail"
  match 'welcome/versions', :to => "welcome#versions"
  namespace :admin do
    resources :locations
  end
end

