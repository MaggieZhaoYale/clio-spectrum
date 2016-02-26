# -*- encoding : utf-8 -*-

##
# Copyright 2013 EBSCO Information Services
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

module Blacklight::EdsHelperBehavior

  ############
  # Utility functions and libraries
  ############

  require 'fileutils' # for interacting with files
  require "addressable/uri" # for manipulating URLs in the interface
  require "htmlentities" # for deconding/encoding URLs
  require "cgi"
  require 'open-uri'

  def html_unescape(text)
    return CGI.unescape(text)
  end

  # passed a params hash, returns an array??
  # this is all just to apply html_escape recursively to params? 
  # I don't think we need that?
  def deep_clean(parameters)
    tempArray = Array.new;
    parameters.each do |k, v|
      unless v.nil?
        if v.is_a?(Array)
          deeperClean = deep_clean(v)
          parameters[k] = deeperClean
        else
          # e.g.:
          # "boolean_operator1"=>"AND"
          parameters[k] = h(v)
        end
      else
          clean_key = h(k)
          tempArray.push(clean_key)
      end
    end
    unless tempArray.empty?
      parameters = tempArray
    end
    return parameters
  end

  # cleans response from EBSCO API
  def processAPItags(apiString)
    processed = HTMLEntities.new.decode apiString
    return processed.html_safe
  end

  ###########
  # API Interaction
  ###########

  # called at the beginning of every page load
  def eds_connect

    # use session[:debugNotes] to store any debug text
    # this will display if you render the _debug partial
    session[:debugNotes] = ""

    # creates EDS API connection object, initializing it with application login credentials
    @connection = EDSApi::ConnectionHandler.new(2)
    File.open(auth_file_location,"r") {|f|
        @api_userid = f.readline.strip
        @api_password = f.readline.strip
        @api_profile = f.readline.strip
    }
    if authenticated_user?
      session[:debugNotes] << "<p>Sending NO as guest.</p>"
      @connection.uid_init(@api_userid, @api_password, @api_profile, 'n')
    else
      session[:debugNotes] << "<p>Sending YES as guest.</p>"
      @connection.uid_init(@api_userid, @api_password, @api_profile, 'y')
    end

    # generate a new authentication token if their isn't one or the one stored on server is invalid or expired
    if has_valid_auth_token?
      @auth_token = getAuthToken
    else
      @connection.uid_authenticate(:json)
      @auth_token = @connection.show_auth_token
      writeAuthToken(@auth_token)
    end

    # generate a new session key if there isn't one, or if the existing one is invalid
    if session[:session_key].present?
      if session[:session_key].include?('Error')
        @session_key = @connection.create_session(@auth_token)
        session[:session_key] = @session_key
        get_info
      else
        @session_key = session[:session_key]
      end
    else
      @session_key = @connection.create_session(@auth_token, 'n')
      session[:session_key] = @session_key
      get_info
    end

    # at this point, we should have a valid authentication and session token

  end


  # after basic functions like SEARCH, INFO, and RETRIEVE, check to make sure a new session token wasn't generated
  # if it was, use the new session key from here on out
  def checkSessionCurrency
    currentSessionKey = @connection.show_session_token
    if currentSessionKey != get_session_key
      session[:session_key] = currentSessionKey
      @session_key = currentSessionKey
      get_info
    end
  end

  SEARCH_FIELDS = {
    'author'   => 'AU',
    'subject'  => 'SU',
    'title'    => 'TI',
    'source'   => 'SO',
    'abstract' => 'AB',
    'issn'     => 'IS',
    'isbn'     => 'IB'
  }
  SEARCH_CODES = SEARCH_FIELDS.invert

  # Take a raw search-field param, and return a valid search-field 
  # formatted for prefixing the query (i.e., include the colon)
  # Unrecognized values or nil return empty string ('') for 'All Fields'
  def search_field_prefix(search_field = '')
    if found = SEARCH_FIELDS[search_field]
      return found + ':'
    else
      return ''
    end
  end

  def search_field_label(code = '')
    if found = SEARCH_CODES[code]
      return found
    else
      return ''
    end
  end

  BOOLEAN_OPERATORS = [ 'AND', 'OR', 'NOT' ]

  # Take a raw boolean_operator param, and return a valid boolean_operator
  # formatted for prefixing the query (i.e., include the comma delimiter)
  # Unrecognized values or nil return 'AND'.
  def boolean_operator_prefix(boolean_operator = 'AND')
    case boolean_operator
    when 'AND'
      'AND,'
    when 'OR'
      'OR,'
    when 'NOT'
      'NOT,'
    else
      'AND,'
    end
  end

  # generates parameters for the API call given URL parameters
  # options is usually the params hash
  # this function strips out unneeded parameters and reformats them 
  # to form a string that the API accepts as input
  def generate_api_query(options)

    #removing Rails and Blacklight parameters
    options.delete("action")
    options.delete("controller")
    options.delete("utf8")

    # This will be the hash of EDS-supported options
    eds_options  = {}

    # Handle q/search_field/search_mode, without an index,
    # by bumping them into "1"
    options['q1'] = options['q'] if options['q']
    options['search_field1'] = options['search_field'] if options['search_field']
    options['search_mode1'] = options['search_mode'] if options['search_mode']

    # # These fold into "query-1" for EDS.
    # if options["q"]
    #   eds_options["query-1"] = options["q"]
    #   # translate names (title) to EDS codes (TI) [nil maps to empty-string]
    #   search_field = options["search_field"]
    #   eds_options["query-1"] = search_field_prefix(search_field) +
    #                             eds_options["query-1"]
    #   # validate and prepend "boolean" operator, [default to AND]
    #   boolean_operator = options["boolean_operator"]
    #   eds_options["query-1"] = boolean_operator_prefix(boolean_operator) +
    #                             eds_options["query-1"]
    # end

    # The search form may submit multiple searchfield/searchfield/q triples,
    # with an index appended.  (Even #1 may come to us with a '1' index.)
    (1..9).each do |i|
      qN = options["q#{i}"]
      if qN && qN.length > 0
        eds_options["query-#{i}"] = qN
        # translate names (title) to EDS codes (TI) [nil maps to empty-string]
        search_field = options["search_field#{i}"]
        # raise
        eds_options["query-#{i}"] = search_field_prefix(search_field) +
                                  eds_options["query-#{i}"]
        # validate and prepend "boolean" operator, [default to AND]
        boolean_operator = options["boolean_operator#{i}"]
        eds_options["query-#{i}"] = boolean_operator_prefix(boolean_operator) +
                                  eds_options["query-#{i}"]
      end
    end
# raise

    # 
    # #translate Blacklight search_field into query index
    # if options["search_field"].present?
    #   if options["search_field"] == "author"
    #     fieldcode = "AU:"
    #   elsif options["search_field"] == "subject"
    #     fieldcode = "SU:"
    #   elsif options["search_field"] == "title"
    #     fieldcode = "TI:"
    #   elsif options["search_field"] == "source"
    #     fieldcode = "SO:"
    #   elsif options["search_field"] == "abstract"
    #     fieldcode = "AB:"
    #   elsif options["search_field"] == "issn"
    #     fieldcode = "IS:"
    #   elsif options["search_field"] == "isbn"
    #     fieldcode = "IB:"
    #   else
    #     fieldcode = ""
    #   end
    # else
    #   fieldcode = ""
    # end
    # 
    # #should write something to allow this to be overridden
    # search_mode = "AND"
    # # The only non-default mode is "OR".  If it's passed, respect it.
    # search_mode = "OR" if options['search_mode'] && options['search_mode'] == 'OR'

    # #build 'query-1' API URL parameter
    # searchquery_extras = search_mode + "," + fieldcode

    #filter to make sure the only parameters put into the API query are those that are expected by the API
    # edsKeys = ["eds_action","q","query-1","facetfilter[]","facetfilter","sort","includefacets","search_mode","view","resultsperpage","sort","pagenumber","highlight", "limiter", "limiter[]", "defaultdb"]
    # Don't include q/search_field/search_mode - we handled those above.
    edsKeys = ["eds_action", "facetfilter[]", "facetfilter", "sort",
               "includefacets", "search_mode", "view", "resultsperpage",
               "sort", "pagenumber", "highlight", "limiter", "limiter[]", "defaultdb"]
    options.each do |key, value|
      if edsKeys.include?(key)
        eds_options[key] = value
      end
    end

    #rename parameters to expected names
    #action and query-1 were renamed due to Rails and Blacklight conventions respectively
    mappings = {"eds_action" => "action", "q" => "query-1"}
    eds_options = Hash[eds_options.map {|k, v| [mappings[k] || k, v] }]

    # #repace the raw query, adding search_mode and fieldcode
    # changedQuery = searchquery_extras.to_s + newoptions["query-1"].to_s
    # session[:debugNotes] << "CHANGEDQUERY: " << changedQuery.to_s
    # newoptions["query-1"] = changedQuery

#    uri = Addressable::URI.new
#    uri.query_values = newoptions
#    searchquery = uri.query
#    debugNotes << "SEARCH QUERY " << searchquery.to_s
#    searchtermindex = searchquery.index('query-1=') + 8
#    searchquery.insert searchtermindex, searchquery_extras

    Rails.logger.debug "======== eds_options=[#{eds_options.inspect}]"
# raise
    searchquery = eds_options.to_query
    Rails.logger.debug "======== searchquery=[#{searchquery.to_s}]"
    # , : ( ) - unencoding expected punctuation
    # session[:debugNotes] << "<p>SEARCH QUERY AS STRING: " << searchquery.to_s
#    searchquery = CGI::unescape(searchquery)
#    session[:debugNotes] << "<br />ESCAPED: " << searchquery.to_s
    searchquery = searchquery.gsub('limiter%5B%5D','limiter').gsub('facetfilter%5B%5D','facetfilter')
    searchquery = searchquery.gsub('%28','(').gsub('%3A',':').gsub('%29',')').gsub('%23',',')
#    searchquery = searchquery.gsub(':','%3A')
    # session[:debugNotes] << "<br />FINAL: " << searchquery.to_s << "</p>"
    return searchquery
  end


  # main search function.  accepts string to be tacked on to API endpoint URL
  def search(apiquery)
    Rails.logger.debug("====== search(#{apiquery.to_s})")
    session[:debugNotes] << "<p>API QUERY SENT: " << apiquery.to_s << "</p>"
    results = @connection.search(apiquery, @session_key, @auth_token, :json).to_hash
    # raise

    #update session_key if new one was generated in the call
    checkSessionCurrency

    #results are stored in the session to facilitate faster navigation between detailed records and results list without needed a new API call
    session[:results] = results
    session[:apiquery] = apiquery

# raise

  end


  def retrieve(dbid, an, highlight = "")
    session[:debugNotes] << "HIGHLIGHTBEFORE:" << highlight.to_s
    highlight.downcase!
    highlight.gsub! ',and,',','
    highlight.gsub! ',or,',','
    highlight.gsub! ',not,',','
    session[:debugNotes] << "HIGHLIGHTAFTER: " << highlight.to_s
    record = @connection.retrieve(dbid, an, highlight, @session_key, @auth_token, :json).to_hash
    session[:debugNotes] << "RECORD: " << record.to_s
    #update session_key if new one was generated in the call
    checkSessionCurrency

    return record
  end

  def termsToHighlight(terms = "")
    if terms.present?
      words = terms.split(/\W+/)
      return words.join(",").to_s
    else
      return ""
    end
  end

  # helper function for iterating through results from 
  def switch_link(params,qurl)

    # check to see if the user is navigating to a record that was not included in the current page of results
    # if so, run a new search API call, getting the appropriate page of results
    if params[:resultId].to_i > (params[:pagenumber].to_i * params[:resultsperpage].to_i)
      nextPage = params[:pagenumber].to_i + 1
      newParams = params
      newParams[:eds_action] = "GoToPage(" + nextPage.to_s + ")"
      options = generate_api_query(newParams)
      search(options)
    elsif params[:resultId].to_i < (((params[:pagenumber].to_i - 1) * params[:resultsperpage].to_i) + 1)
      nextPage = params[:pagenumber].to_i - 1
      newParams = params
      newParams[:eds_action] = "GoToPage(" + nextPage.to_s + ")"
      options = generate_api_query(newParams)
      search(options)
    end

    link = ""
    # generate the link for the target record
    if session[:results]['SearchResult']['Data']['Records'].present?
      session[:results]['SearchResult']['Data']['Records'].each do |result|
        nextId = show_resultid(result).to_s
        if nextId == params[:resultId].to_s
          nextAn = show_an(result).to_s
          nextDbId = show_dbid(result).to_s
          nextrId = params[:resultId].to_s
          nextHighlight = params[:q].to_s
          link = request.fullpath.split("/switch")[0].to_s + "/" + nextDbId.to_s + "/" + nextAn.to_s + "/?resultId=" + nextrId.to_s + "&highlight=" + nextHighlight.to_s
        end
      end
    end
    return link.to_s

  end

  # calls the INFO API method
  # counts how many limiters are available
  def get_info

    numLimiters = 0
    session[:info] = @connection.info(@session_key, @auth_token, :json).to_hash
    checkSessionCurrency

    if session[:info].present?
      if session[:info]['AvailableSearchCriteria'].present?
        if session[:info]['AvailableSearchCriteria']['AvailableLimiters'].present?
          session[:info]['AvailableSearchCriteria']['AvailableLimiters'].each do |limiter|
            if limiter["Type"] == "select"
              numLimiters += 1
            end
          end
        end
      end
    end

    session[:numLimiters] = numLimiters
  end

  ############
  # File / Token Handling / End User Auth
  ############

  def authenticated_user?

    # If we're on-campus, or have a current_user, then we're authenticated.
    return true if @user_characteristics[:on_campus] || !current_user.nil?
    # otherwise, we're not.
    return false

    # if user_signed_in?
    #   return true
    # end
    # # need to define function for detecting on-campus IP ranges
    # return false
  end

  def clear_session_key
    # Does anyone call this?
    raise
    session.delete(:session_key)
  end

  def get_session_key
    if session[:session_key].present?
      return session[:session_key].to_s
    else
      return "no session key"
    end
  end

  def token_file_exists?
    if File.exists?(token_file_location)
      return true
    end
    # marquis - this seems incorrect
    # return Rails.root.to_s + "/token.txt"
    return false
  end

  def auth_file_exists?
    if File.exists?(auth_file_location)
      return true
    end
    # return Rails.root.to_s + "/APIauthentication.txt"
    return false
  end

  def token_file_location
    # I think we don't need this - our localhost
    # development still uses Rails.
    # if request.domain.to_s.include?("localhost")
    #   return "token.txt"
    # end
    return Rails.root.to_s + "/token.txt"
  end

  def auth_file_location
    # if request.domain.to_s.include?("localhost")
    #   return "APIauthentication.txt"
    # end
    return Rails.root.to_s + "/APIauthentication.txt"
  end

  # returns true if the authtoken stored in token.txt is valid
  # false if otherwise
  def has_valid_auth_token?
    token = timeout = timestamp = ''
    if token_file_exists?
      File.open(token_file_location,"r") {|f|
        if f.readlines.size <= 2
          return false
        end
      }
      File.open(token_file_location,"r") {|f|
          token = f.readline.strip
          timeout = f.readline.strip
          timestamp = f.readline.strip
      }
    else
      return false
    end
    if Time.now.getutc.to_i < timestamp.to_i
      return true
    else
      session[:debugNotes] << "<p>Looks like the auth token is out of date.. It expired at " << Time.at(timestamp.to_i).to_s << "</p>"
      return false
    end
  end

  def get_token_timeout
    timestamp = '';
    File.open(token_file_location,"r") {|f|
        token = f.readline.strip
        timeout = f.readline.strip
        timestamp = f.readline.strip
    }
    return Time.at(timestamp.to_i)
  end

  # writes an authentication token to token.txt.
  # will create token.txt if it does not exist
  def writeAuthToken(auth_token)
    timeout = "1800"
    timestamp = Time.now.getutc.to_i + timeout.to_i
    timestamp = timestamp.to_s
    auth_token = auth_token.to_s

    if File.exists?(token_file_location)
      File.open(token_file_location,"w") {|f|
        f.write(auth_token)
        f.write("\n" + timeout)
        f.write("\n" + timestamp)
      }
    else
      File.open(token_file_location,"w") {|f|
        f.write(auth_token)
        f.write("\n" + timeout)
        f.write("\n" + timestamp)
      }
      # update from '664' to '0664'
      File.chmod(0664,token_file_location)
      File.open(token_file_location,"w") {|f|
        f.write(auth_token)
        f.write("\n" + timeout)
        f.write("\n" + timestamp)
      }
    end
  end

  def getAuthToken
    token = ''
    timeout = ''
    timestamp = ''
    if has_valid_auth_token?
      File.open(token_file_location,"r") {|f|
        token = f.readline.strip
      }
      return token
    end
    return token
  end


  ############
  # Linking Utilities
  ############

  # pulls <QueryString> from the results of the current search to serve as the baseURL for next request
  def generate_next_url
    # raise
    return '' unless session[:results].present?

    # the query string is only the cgi params, not a full or relative URL
    query_string = HTMLEntities.new.decode(session[:results]['SearchRequestGet']['QueryString'])
    query_params = CGI.parse(query_string)

    # CGI.parse sets all values to arrays.  Undo this.
    query_params.each do |key, value|
      query_params[key] = value[0] if (value.kind_of?(Array) && value.length == 1)
    end

    # Map the EDS syntax of the QueryString back into application param syntax.
    # query-N is broken into qN, search_fieldN, boolean_operatorN
    (1..9).each do |i|
      if query = query_params.delete("query-#{i}")

        # peel off the leading boolean (and comma), store in it's own param
        bools = BOOLEAN_OPERATORS.join('|')
        if matched = query.match(/#{bools}/)
          query_params["boolean_operator#{i}"] = matched.to_s
          query.gsub!(/#{matched.to_s},/, '')
        end

        # peel off the leading search field code (and colon), store in it's own param
        codes = SEARCH_CODES.keys.join('|')
        # raise
        if matched = query.match(/#{codes}/)
          query_params["search_field#{i}"] = SEARCH_CODES[matched.to_s]
          query.gsub!(/#{matched.to_s}:/, '')
        end

        # move the query over to the "q"
        query_params["q#{i}"] = query
      end
    end

    # bump "q1" back to a simple "q"
    if q1 = query_params.delete('q1')
      query_params['q'] = q1
    end


    # #blacklight expects the search term to be in the parameter 'q'.
    # #q is moved back to 'query-1' in 'generate_api_query'
    # #should probably pull from Info method to determine replacement strings
    # #i could turn the query into a Hash, but available functions to do so delete duplicated params (Addressable)
    # url.gsub!("query-1=AND,TI:","q=")
    # url.gsub!("query-1=AND,AU:","q=")
    # url.gsub!("query-1=AND,SU:","q=")
    # url.gsub!("query-1=AND,SO:","q=")
    # url.gsub!("query-1=AND,AB:","q=")
    # url.gsub!("query-1=AND,IS:","q=")
    # url.gsub!("query-1=AND,IB:","q=")
    # url.gsub!("query-1=AND,","q=")

    #Rails framework doesn't allow repeated params.  turning these into arrays fixes it.
    # url.gsub!("facetfilter=","facetfilter[]=")
    # url.gsub!("limiter=","limiter[]=")
    # if facetfilter = query_params.delete('facetfilter')
    #   query_params['facetfilter[]'] = facetfilter
    # end
    # if limiter = query_params.delete('limiter')
    #   query_params['limiter[]'] = limiter
    # end

    # #i should probably pull this from the query, not the URL
    # if (params[:search_field]).present?
    #   url << "&search_field=" << params[:search_field].to_s
    # end

    # return url
# Rails.logger.debug "+++  generate_next_url() returning:  #{query_params.to_query}"
    return query_params.to_query

  end

  # should replace this functionality with AddQuery/RemoveQuery actions
  def generate_next_url_newvar_from_hash(variablehash)
    uri = Addressable::URI.parse(request.fullpath.split("?")[0] + "?" + generate_next_url)
    newUri = uri.query_values.merge variablehash
    uri.query_values = newUri
    return uri.query.to_s
  end

  #for the search form at the top of results
  #retains some of current search's fields (limiters)
  #discards pagenumber, facets and filters, actions, etc.
  def show_hidden_field_tags
    hidden_fields = "";
    params.each do |key, value|
      unless ((key == "search_field") or (key == "fromDetail") or (key == "facetfilter") or (key == "pagenumber") or (key == "q") or (key == "dbid") or (key == "an"))
        if (key == "eds_action")
          if ((value.scan(/addlimiter/).length > 0) or (value.scan(/removelimiter/).length > 0) or (value.scan(/setsort/).length > 0) or (value.scan(/SetResultsPerPage/).length > 0))
            hidden_fields << '<input type="hidden" name="' << key.to_s << '" value="' << value.to_s << '" />'
          end
        elsif value.kind_of?(Array)
          value.each do |arrayVal|
            hidden_fields << '<input type="hidden" name="' << key.to_s << '[]" value="' << arrayVal.to_s << '" />'
          end
        else
          hidden_fields << '<input type="hidden" name="' << key.to_s << '" value="' << value.to_s << '" />'
        end
      end
    end
    return hidden_fields.html_safe
  end

  ###########
  # Pagination
  ###########

  #display how many results are being shown      
  def show_results_per_page
    if params[:eds_action].present?
      if params[:eds_action].to_s.scan(/SetResultsPerPage/).length > 0
        rpp = params[:eds_action].to_s.gsub("SetResultsPerPage(","").gsub(")","").to_i
        return rpp
      end
    end
    if params[:resultsperpage].present?
      return params[:resultsperpage].to_i
    end
    return 20
  end

  #calculates total number of pages in results set
  def show_total_pages
    pages = show_total_hits / show_results_per_page
    return pages + 1
  end

  #get current page, which serves as a base for most pagination functions      
  def show_current_page
    if params[:eds_action].present?
      if params[:eds_action].scan(/GoToPage/).length > 0
        pagenum = params[:eds_action].to_s
        newpagenum = pagenum.gsub("GoToPage(","")
        newpagenum = newpagenum.gsub(")","")
        return newpagenum.to_i
      elsif params[:eds_action].scan(/SetResultsPerPage/).length > 0
        if params[:pagenumber].present?
          return params[:pagenumber].to_i
        else
          return 1
        end
      else
        return 1
      end
    end
    if params[:pagenumber].present?
      return params[:pagenumber].to_i
    end
    return 1
  end

  #display pagination at the top of the results list
  def show_compact_pagination
    previous_link = ''
    next_link = ''
    first_result_on_page_num = ((show_current_page - 1) * show_results_per_page) + 1
    last_result_on_page_num = first_result_on_page_num + show_results_per_page - 1
    if last_result_on_page_num > show_total_hits
      last_result_on_page_num = show_total_hits
    end
    page_info = "<strong>" + first_result_on_page_num.to_s + "</strong> - <strong>" + last_result_on_page_num.to_s + "</strong> of <strong>" + number_with_delimiter(show_total_hits) + "</strong>"
    if show_current_page > 1
      previous_page = show_current_page - 1
      previous_link = '<a href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=GoToPage(" + previous_page.to_s + ')">&laquo; Previous</a> | '
    end
    if (show_current_page * show_results_per_page) < show_total_hits
      next_page = show_current_page + 1
      next_link = ' | <a href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=GoToPage(" + next_page.to_s + ')">Next &raquo;</a>'
    end
    compact_pagination = previous_link + page_info + next_link
    return compact_pagination.html_safe
  end

  #bottom pagination.  commented out lines remove 'last page' link, as this is not currently supported by the API
  def show_pagination
    previous_link = ''
    next_link = ''
    page_num_links = ''

    if show_current_page > 1
      previous_page = show_current_page - 1
      previous_link = '<li class=""><a href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=GoToPage(" + previous_page.to_s + ')">&laquo; Previous</a></li>'
    else
      previous_link = '<li class="disabled"><a href="">&laquo; Previous</a></li>'
    end

    if (show_current_page * show_results_per_page) < show_total_hits
      next_page = show_current_page + 1
      next_link = '<li class=""><a href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=GoToPage(" + next_page.to_s + ')">Next &raquo;</a></li>'
    else
      next_link = '<li class="disabled"><a href="">Next &raquo;</a></li>'
    end

    if show_current_page >= 4
      page_num_links << '<li class=""><a href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=GoToPage(" + 1.to_s + ')">1</a></li>'
    end
    if show_current_page >= 5
      page_num_links << '<li class="disabled"><a href="">...</a></li>'
    end

    # show links to the two pages the the left and right (where applicable)
    bottom_page = show_current_page - 2
    if bottom_page <= 0
      bottom_page = 1
    end
    top_page = show_current_page + 2
    if top_page >= show_total_pages
      top_page = show_total_pages
    end
    (bottom_page..top_page).each do |i|
      unless i == show_current_page
        page_num_links << '<li class=""><a href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=GoToPage(" + i.to_s + ')">' + i.to_s + '</a></li>'
      else
        page_num_links << '<li class="disabled"><a href="">' + i.to_s + '</a></li>'
      end
    end

    if show_total_pages >= (show_current_page + 3)
      page_num_links << '<li class="disabled"><a href="">...</a></li>'
    end

    pagination_links = previous_link + next_link + page_num_links
    return pagination_links.html_safe
  end

  #############
  # Facet / Limiter Constraints Box
  #############

  def query_has_results?()
    session[:results] &&
    session[:results]['SearchResult'] &&
    session[:results]['SearchResult']['Data'] &&
    session[:results]['SearchResult']['Data']['Records']
  end


  def query_has_search_terms?()
    # But maybe "q" is present, together with "eds_action=removequery(1)".
    # return true if params[:q]
    # (1..9).each do |i|
    #   return true if params["q#{i}"] || params["query-#{i}"]
    # end
    # return false
    # Better to directly check the active Query as echoed back from the API endpoint.

    session[:results] &&
    session[:results]['SearchRequestGet'] &&
    session[:results]['SearchRequestGet']['SearchCriteriaWithActions'] &&
    session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['QueriesWithAction']
  end

  # used when determining if "constraints" should display
  def query_has_facetfilters?()
    session[:results] &&
    session[:results]['SearchRequestGet'] &&
    session[:results]['SearchRequestGet']['SearchCriteriaWithActions'] &&
    session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['FacetFiltersWithAction']

    # generate_next_url.scan("facetfilter[]=").length > 0
  end

  # used when determining if "constraints" should display
  def query_has_limiters?()
    session[:results] &&
    session[:results]['SearchRequestGet'] &&
    session[:results]['SearchRequestGet']['SearchCriteriaWithActions'] &&
    session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['LimitersWithAction']

    # generate_next_url.scan("limiter[]=").length > 0
  end

  def limiter_label(limiter = nil)
    return '' if limiter.nil?

    # map the ID to a display string
    limiterLabel = limiter_id_to_label(limiter['Id'])

    # that's it.  Unless we're a Date limiter.
    return limiterLabel unless limiter['Id'] == 'DT1'

    # Only process the first applied date limit.  Multiple date limits would be very, very odd.
    limiterValue = limiter["LimiterValuesWithAction"][0]["Value"]

    # Are EDS date limit values look like this:   "Value"=>"2010-01/2015-12"
    return limiterLabel.titlecase + ' ' + limiterValue.gsub("-01/", " - ").gsub("-12", "")
  end

  def limiter_id_to_label(id = nil)
    return '' if id.nil?

    # make sure we've got session metadata
    get_info unless session[:info].present?

    # find the labels from our session metadata
    session[:info]['AvailableSearchCriteria']['AvailableLimiters'].each do |limiter|
      return limiter['Label'] if limiter["Id"] == id
    end

    return ''
  end


# # marquis - moved this to a partial, _applied_facets.html.haml
#   # should probably return a hash and let the view handle the HTML
#   def show_applied_facets
#     appliedfacets = '';
#     if session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['FacetFiltersWithAction'].present?
#       session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['FacetFiltersWithAction'].each do |appliedfacet|
#         appliedfacet.each do |key, val|
#           if key == "FacetValuesWithAction"
#             val.each do |facetValue|
#               appliedfacets << '<span class="btn-group appliedFilter constraint filter filter-' + facetValue['FacetValue']['Id'].to_s.gsub("EDS","").gsub(" ","").titleize + '"><a class="constraint-value btn btn-sm btn-default btn-disabled" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + CGI.escape(facetValue['RemoveAction'].to_s) + '"><span class="filterName">' + facetValue['FacetValue']['Id'].to_s.gsub("EDS","").titleize + '</span><span class="filterValue">' + facetValue['FacetValue']['Value'].to_s.titleize + '</span></a><a class="btn btn-default btn-sm remove dropdown-toggle" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + CGI.escape(facetValue['RemoveAction'].to_s) + '"><span class="glyphicon glyphicon-remove"></span><span class="sr-only">Remove filter ' + facetValue['FacetValue']['Id'].to_s.gsub("EDS","").titleize + ':' + facetValue['FacetValue']['Value'].to_s.titleize + '</span></a></span>'
#             end
#           end
#         end
#       end
#     end
#     return appliedfacets.html_safe
#   end


# # marquis - moved this to a partial, _applied_limiters.html.haml
#   # should return hash and let the view handle the HTML
#   def show_applied_limiters
#     appliedlimiters = '';
#     if session[:results].present?
#       if session[:results]['SearchRequestGet']['SearchCriteriaWithActions'].present?
#         if session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['LimitersWithAction'].present?
#           session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['LimitersWithAction'].each do |appliedLimiter|
#             limiterLabel = "No Label"
#             session[:info]['AvailableSearchCriteria']['AvailableLimiters'].each do |limiter|
#               if limiter["Id"] == appliedLimiter["Id"]
#                 limiterLabel = limiter["Label"]
#               end
#             end
#             if appliedLimiter["Id"] == "DT1"
#               appliedLimiter["LimiterValuesWithAction"].each do |limiterValues|
#                 appliedlimiters << '<span class="btn-group appliedFilter constraint filter filter-' + appliedLimiter["Id"] + '">'
#                 appliedlimiters << '<a class="constraint-value btn btn-sm btn-default btn-disabled" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + appliedLimiter["RemoveAction"].to_s + '">'
#                 appliedlimiters << '<span class="filterName">' + limiterLabel.to_s.titleize + '</span><span class="filterValue">' + limiterValues["Value"].gsub("-01/"," to ").gsub("-12","") + '</span>'
#                 appliedlimiters << '</a><a class="btn btn-default btn-sm remove dropdown-toggle" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + appliedLimiter["RemoveAction"].to_s + '">'
#                 appliedlimiters << '<span class="glyphicon glyphicon-remove"></span><span class="sr-only">Remove limiter '+ limiterLabel.to_s.titleize + ':' + limiterValues["Value"].gsub("-01/"," to ").gsub("-12","") + '</a></span>'
#               end
#             else
#               appliedlimiters << '<span class="btn-group appliedFilter constraint filter filter-' + appliedLimiter["Id"] + '"><a class="constraint-value btn btn-sm btn-default btn-disabled" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + appliedLimiter["RemoveAction"].to_s + '"><span class="filterValue">' + limiterLabel.to_s.titleize + '</span></a><a class="btn btn-default btn-sm remove dropdown-toggle" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + appliedLimiter["RemoveAction"].to_s + '"><span class="glyphicon glyphicon-remove"></span><span class="sr-only">Remove limiter ' + limiterLabel.to_s.titleize + '</span></a></span>'
#             end
#           end
#         end
#       end
#     end
#     return appliedlimiters.html_safe
#   end

  #############
  # Facets / Limiters sidebar
  #############

  # check to see if result has any facets.  
  def has_eds_facets?
    # crude, and I forget why I had to do a length check..
    # (show_facets.length > 5)

    # marquis - show_facets() generates complex hardcoded HTML.
    # don't use that.  instead, check directly.
    return true if session[:results] and
                   session[:results]['SearchResult'] and
                   session[:results]['SearchResult']['AvailableFacets']
  end

  def show_numlimiters
    unless session[:numLimiters].present?
      get_info
    end
    return session[:numLimiters]
  end

  # show limiters on the view
  def show_limiters
    limiterCount = 0;
    limitershtml = '';
    unless session[:info].present?
      get_info
    end
    if session[:info]['AvailableSearchCriteria']['AvailableLimiters'].present?
      limitershtml << '<div class="panel panel-default facet_limit blacklight-Limiters"><div class="collapse-toggle panel-heading" data-target="#facet-Limiters" data-toggle="collapse"><h5 class="panel-title"><a href="#" data-no-turbolink="true">Search Options</a></h5></div><div id="facet-Limiters" class="panel-collapse facet-content collapse in" style="height: auto;"><div class="panel-body"><form class="form"><ul class="facet-values list-unstyled">'
      session[:info]['AvailableSearchCriteria']['AvailableLimiters'].each do |limiter|
        if limiter["Type"] == "select"
          limiterChecked = false
          limiterAction = limiter["AddAction"].to_s.gsub('value','y')
          if session[:results].present?
            if session[:results]['SearchRequestGet']['SearchCriteriaWithActions'].present?
              if session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['LimitersWithAction'].present?
                session[:results]['SearchRequestGet']['SearchCriteriaWithActions']['LimitersWithAction'].each do |appliedLimiter|
                  if appliedLimiter["Id"] == limiter["Id"]
                    limiterChecked = true
                    limiterAction = appliedLimiter["RemoveAction"].to_s
                  end
                end
              end
            end
          end
          limitershtml << "<li style='font-size:small;'>"
          redirect_url = request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + limiterAction
          limitershtml << check_box_tag("limiters", limiterAction, limiterChecked, :id => ("limiter-" + limiterCount.to_s), :style => "margin-top:-5px;", data: {redirect_url: redirect_url}, class: 'redirect_on_click')
          limitershtml << label_tag("limiter-" + limiterCount.to_s, limiter["Label"])
          # limitershtml << " " << limiter["Label"] << "</li>"
          limitershtml << "</li>"
          limiterCount += 1
        end
      end
      limitershtml << '</ul></form></div></div></div>'
      return limitershtml.html_safe
    else
      return session[:info].to_s
    end
  end

  def show_date_options
    dateString = ""
    timeObj = Time.new
    currentYear = timeObj.year
    fiveYearsPrior = currentYear - 5
    tenYearsPrior = currentYear - 10
    dateString << '<div class="panel panel-default facet_limit blacklight-Date"><div class="collapse-toggle panel-heading collapsed" data-toggle="collapse" data-target="#facet-Date"><h5 class="panel-title"><a data-no-turbolink="true" href="#">Date</a></h5></div><div id="facet-Date" class="panel-collapse facet-content collapse"><div class="panel-body"><ul class="facet-values list-unstyled">'
    dateString << '<li><span class="facet-label"><a href="' << request.fullpath.split("?")[0] << "?" << generate_next_url << '&eds_action=addlimiter(DT1:' << fiveYearsPrior.to_s << '-01/' << currentYear.to_s << '-12)">Last 5 Years</a></span></li>'
    dateString << '<li><a href="' << request.fullpath.split("?")[0] << "?" << generate_next_url << '&eds_action=addlimiter(DT1:' << tenYearsPrior.to_s << '-01/' << currentYear.to_s << '-12)">Last 10 Years</a></li>'
    dateString << '</ul></div></div></div>'
    return dateString.html_safe
  end

# marquis - moved to haml
  # # show available facets
  # def show_facets
  #   facets = '';
  #   if session[:results]['SearchResult']['AvailableFacets'].present?
  #     session[:results]['SearchResult']['AvailableFacets'].each do |facet|
  #       facets = facets + '<div class="panel panel-default facet_limit blacklight-' + facet['Id'] + '"><div class="collapse-toggle panel-heading collapsed" data-target="#facet-' + facet['Id'] + '" data-toggle="collapse"><h5 class="panel-title"><a href="#" data-no-turbolink="true">' + facet['Label'] + '</a></h5></div><div id="facet-' + facet['Id'] + '" class="panel-collapse facet-content collapse"><div class="panel-body"><ul class="facet-values list-unstyled">'
  #       facet.each do |key, val|
  #         if key == "AvailableFacetValues"
  #           val.each do |facetValue|
  #             facets = facets + '<li><span class="facet-label"><a class="facet_select" href="' + request.fullpath.split("?")[0] + "?" + generate_next_url + "&eds_action=" + CGI.escape(facetValue['AddAction'].to_s) + '">' + facetValue['Value'].to_s.titleize + '</a></span> <span class="facet-count">' + facetValue['Count'].to_s + '</span></li>'
  #           end
  #         end
  #       end
  #       facets = facets + '</ul></div></div></div>'
  #     end
  #   end
  #   return facets.html_safe
  # end


  #############
  # Sort / Display / Record Count
  #############

  # pull sort options from INFO method
  def show_sort_options
    sortDropdown = "";
    if session[:info]['AvailableSearchCriteria']['AvailableSorts'].present?
      session[:info]['AvailableSearchCriteria']['AvailableSorts'].each do |sortOption|
        sortDropdown << '<li><a href="' << request.fullpath.split("?")[0] + "?" + generate_next_url << '&eds_action=' << sortOption["AddAction"].to_s << '">' << sortOption["Label"].to_s << '</a></li>'
      end
    end
    return sortDropdown.html_safe
  end

  # shows currently selected view
  def show_view_option
    uri = Addressable::URI.parse(request.fullpath.split("?")[0] + "?" + generate_next_url)
    newUri = uri.query_values
    if newUri['view'].present?
      view_option = newUri['view'].to_s
    else
      view_option = "detailed"
    end
    return view_option
  end

  # shows currently selected sort
  def show_current_sort
    allsorts = '';
    if params[:eds_action].present?
      if params[:eds_action].to_s.scan(/setsort/).length > 0
        currentSort = params[:eds_action].to_s.gsub("setsort(","").gsub(")","")
        if session[:info]['AvailableSearchCriteria']['AvailableSorts'].present?
          session[:info]['AvailableSearchCriteria']['AvailableSorts'].each do |sortOption|
            if sortOption['Id'] == currentSort
              return "Sort by " << sortOption["Label"]
            end
          end
        end
      end
    end
    if params[:sort].present?
      if session[:info]['AvailableSearchCriteria']['AvailableSorts'].present?
        session[:info]['AvailableSearchCriteria']['AvailableSorts'].each do |sortOption|
          if sortOption['Id'].to_s == params[:sort].to_s
            return "Sort by " << sortOption["Label"]
          end
        end
      end
    end
    return 'Sort by Relevance'
  end

  ###############
  # Results List
  ###############

  def has_restricted_access?(result)
    if result['Header']['AccessLevel'].present?
      if result['Header']['AccessLevel'] == '1'
        return true
      end
    end
    return false
  end

  def show_total_hits
    # raise
    return session[:results]['SearchResult']['Statistics']['TotalHits']
  end

  # Each result should have the following structure...
  # {"ResultId"=>1,
  #    "Header"=>{
  #       "DbId"=>"edsamd",
  #       "DbLabel"=>"Adam Matthew Digital",
  #       "An"=>"edsamd.084FAE6D06CD3BE5",
  #       "RelevancyScore"=>"2252",
  #       "PubType"=>"Primary Source",
  #       "PubTypeId"=>"primarySource"
  #     },
  #   
  def has_dblabel?(result)
    return result['Header'] && result['Header']['DbLabel']
  end

  # display title given a single result
  def show_dblabel(result)
    dblabel = ''
    if result['Header'] && result['Header']['DbLabel']
      dblabel = result['Header']['DbLabel']
    end
    return dblabel.html_safe
  end


  # see if title is available given a single result
  def has_titlesource?(result)
    if result['Items'].present?
      result['Items'].each do |item|
        if item['Group'].downcase == "src"
          return true
        end
        if item['Group'].downcase == "ti" and item['Label'].downcase == 'source'
          return true
        end
      end
    end
    return false
  end

  # display title given a single result
  def show_titlesource(result)
    # raise
    source = ''
    if result['Items'].present?
      result['Items'].each do |item|
        if item['Group'].downcase == "src"
          source = processAPItags(item['Data'].to_s)
        elsif item['Group'].downcase == "ti" and item['Label'].downcase == 'source'
          source = processAPItags(item['Data'].to_s)
        end
      end
    end
    return source.html_safe
  end

  def has_subjects?(result)

    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibEntity'].present?
          if result['RecordInfo']['BibRecord']['BibEntity']['Subjects'].present?
            if result['RecordInfo']['BibRecord']['BibEntity']['Subjects'].count > 0
              return true
            end
          end
        end
      end
    end
    return false
  end

  def show_subjects(result)
    # need to update this to look in granular data fields

    subject_array = []
    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibEntity'].present?
          if result['RecordInfo']['BibRecord']['BibEntity']['Subjects'].present?
            result['RecordInfo']['BibRecord']['BibEntity']['Subjects'].each do |subject|
              if subject['SubjectFull']
                url_vars = {"q" => '"' + subject['SubjectFull'].to_s + '"', "search_field" => "subject"}
                link2 = generate_next_url_newvar_from_hash(url_vars) << "&eds_action=GoToPage(1)"
                if params[:dbid].present?
                  subject_link = '<a href="' + request.fullpath.split("/" + params[:dbid])[0] + "?" + link2 + '">' + subject['SubjectFull'].to_s + '</a>'
                else
                  subject_link = '<a href="' + request.fullpath.split("?")[0] + "?" + link2 + '">' + subject['SubjectFull'].to_s + '</a>'
                end
                subject_array.push(subject_link)
              end
            end
          end
        end
      end
    end
    subject_string = ''
    subject_string = subject_array.join(", ")
    return subject_string.html_safe
  end

  def has_pubdate?(result)
    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibRelationships'].present?
          if result['RecordInfo']['BibRecord']['BibRelationships']['IsPartOfRelationships'].present?
            result['RecordInfo']['BibRecord']['BibRelationships']['IsPartOfRelationships'].each do |isPartOfRelationship|
              if isPartOfRelationship['BibEntity'].present?
                if isPartOfRelationship['BibEntity']['Dates'].present?
                  isPartOfRelationship['BibEntity']['Dates'].each do |date|
                    if date['Type'] == "published"
                      return true
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    return false
  end

  def show_pubdate(result)
    # check to see if there is a PubDate ITEM
    # Wiki Page on ITEM GROUPS
    flag = 0
    pubdate = ''
    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibRelationships'].present?
          if result['RecordInfo']['BibRecord']['BibRelationships']['IsPartOfRelationships'].present?
            result['RecordInfo']['BibRecord']['BibRelationships']['IsPartOfRelationships'].each do |isPartOfRelationship|
              if isPartOfRelationship['BibEntity'].present?
                if isPartOfRelationship['BibEntity']['Dates'].present?
                  isPartOfRelationship['BibEntity']['Dates'].each do |date|
                    if date['Type'] == "published" and flag == 0
                      flag = 1
                      if date['M'].present? and date['D'].present? and date['Y'].present?
                        pubdate << date['M'] << "/" << date['D'] << "/" << date['Y']
                      elsif date['M'].present? and date['Y'].present?
                        pubdate << date['M'] << "/" << date['Y']
                      elsif date['Y'].present?
                        pubdate << date['Y']
                      else
                        pubdate << "Not available."
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    return pubdate
  end

  def has_pubtype?(result)
    return result['Header']['PubType'].present?
  end

  def show_pubtype(result)
    if has_pubtype?(result)
      return result['Header']['PubType']
    end
    return ''
  end

  def has_pubtypeid?(result)
    return result['Header']['PubTypeId'].present?
  end

  def show_pubtypeid(result)
    if has_pubtypeid?(result)
      return result['Header']['PubTypeId']
    end
    return ''
  end

  def has_coverimage?(result)
    if result['ImageInfo'].present?
      result['ImageInfo'].each do |coverArt|
        if coverArt['Size'] == 'thumb'
          return true
        end
      end
    end
    return false
  end

  def show_coverimage_link(result)
    artUrl = ''
    flag = 0
    if result['ImageInfo'].present?
      result['ImageInfo'].each do |coverArt|
        if coverArt['Size'] == 'thumb' and flag == 0
          artUrl << coverArt['Target']
          flag = 1
        end
      end
    end
    return artUrl
  end

  def has_abstract?(result)
    if result['Items'].present?
      result['Items'].each do |item|
        if item['Group'].present?
          if item['Group'] == "Ab"
            return true
          end
        end
      end
    end
    return false
  end

  def show_abstract(result)
    abstractString = ''
    if result['Items'].present?
      result['Items'].each do |item|
        if item['Group'].present?
          if item['Group'] == "Ab"
            abstractString << item['Data']
          end
        end
      end
    end
    abstract = HTMLEntities.new.decode abstractString
    return abstract.html_safe
  end

  def has_authors?(result)
    if result['Items'].present?
      result['Items'].each do |item|
        if item['Group'].present?
          if item['Group'] == "Au"
            return true
          end
        end
      end
    end
    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibRelationships'].present?
          if result['RecordInfo']['BibRecord']['BibRelationships']['HasContributorRelationships'].present?
            result['RecordInfo']['BibRecord']['BibRelationships']['HasContributorRelationships'].each do |contributor|
              if contributor['PersonEntity'].present?
                return true
              end
            end
          end
        end
      end
    end
    return false
  end

  # this should make use of AddQuery / RemoveQuery - but there might be a conflict with the "q" variable  
  def show_authors(result)
    author_array = []
    if result['Items'].present?
      flag = 0
      authorString = []
      result['Items'].each do |item|
        if item['Group'].present?
          if item['Group'] == "Au"
            # let Don and Michelle know what this cleaner function does
            newAuthor = processAPItags(item['Data'].to_s)
            # i'm duplicating the semicolor - fix
            newAuthor.gsub!("<br />","; ")
            authorString.push(newAuthor)
            flag = 1
          end
        end
      end
      if flag == 1
        return authorString.join("; ").html_safe
      end
    end

    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibRelationships'].present?
          if result['RecordInfo']['BibRecord']['BibRelationships']['HasContributorRelationships'].present?
            result['RecordInfo']['BibRecord']['BibRelationships']['HasContributorRelationships'].each do |contributor|
              if contributor['PersonEntity'].present?
                if contributor['PersonEntity']['Name'].present?
                  if contributor['PersonEntity']['Name']['NameFull'].present?
                    url_vars = {"q" => '"' + contributor['PersonEntity']['Name']['NameFull'].gsub(",","").gsub("%2C","").to_s + '"', "search_field" => "author"}
                    link2 = generate_next_url_newvar_from_hash(url_vars)
                    author_link = '<a href="' + request.fullpath.split("?")[0] + "?" + link2 + '">' + contributor['PersonEntity']['Name']['NameFull'].to_s + '</a>'
                    author_array.push(author_link)
                  end
                end
              end
            end
            return author_array.join("; ").html_safe
          end
        end
      end
    end
    return ''
  end

  def show_resultid(result)
    return result['ResultId'].to_s
  end

  def show_title(result)
    # raise
    Array(result['Items']).each do |item|
      if item['Group'] == 'Ti'
        return HTMLEntities.new.decode(item['Data']).html_safe
      end
    end
    titles = []
    if result['RecordInfo'].present?
      if result['RecordInfo']['BibRecord'].present?
        if result['RecordInfo']['BibRecord']['BibEntity'].present?
          if result['RecordInfo']['BibRecord']['BibEntity']['Titles'].present?
            result['RecordInfo']['BibRecord']['BibEntity']['Titles'].each do |title|
              titles.push title['TitleFull'].to_s
            end
          end
        end
      end
      return titles.join(" / ").html_safe
    end
    return "Title not available."
  end

  def show_results_array
    @results.inspect
  end

  def has_full_text_on_screen?(result)
    if result['FullText'].present?
      if result['FullText']['Text'].present?
        if result['FullText']['Text']['Availability'].present?
          if result['FullText']['Text']['Availability'] == "1"
            return true
          end
        end
      end
    end
  end

  def show_full_text_on_screen(result)
    if result['FullText'].present?
      if result['FullText']['Text'].present?
        if result['FullText']['Text']['Availability'].present?
          if result['FullText']['Text']['Availability'] == "1"
            return HTMLEntities.new.decode(result['FullText']['Text']['Value'])
          end
        end
      end
    end
  end

  ################
  # Full Text Links
  ################

  def has_any_fulltext?(result)
    if has_pdf?(result)
      return true
    elsif has_html?(result)
      return true
    elsif has_smartlink?(result)
      return true
    elsif has_fulltext?(result)
      return true
    elsif has_ebook?(result)
      return true
    end
    return false
  end

  def show_an(result)
    if result['Header'].present?
        if result['Header']['An'].present?
          an = result['Header']['An'].to_s
        end
    end
    return an
  end

  def show_dbid(result)
    if result['Header'].present?
        if result['Header']['DbId'].present?
          dbid = result['Header']['DbId'].to_s
        end
    end
    return dbid
  end

  def show_detail_link(result, resultId = "0", highlight = "")
    # hardcode these links to work from root - relative
    # links were getting confused with non-default actions
    link = "/"
    highlight.gsub! '&quot;', '%22' unless highlight.nil?
    if result['Header'].present?
      if result['Header']['DbId'].present?
        if result['Header']['An'].present?
          link << 'eds/' << result['Header']['DbId'].to_s << '/' << url_encode(result['Header']['An']) << '/'
          if resultId.to_i > "0".to_i and highlight != ""
            link << '?resultId=' << resultId.to_s << '&highlight=' << highlight.to_s
          elsif resultId.to_i > "0".to_i
            link << '?resultId=' << resultId.to_s
          elsif highlight != ""
            link << '?highlight' << highlight.to_s
          end
        end
      end
    end
    return link
  end

  def show_best_fulltext_link(result)
    if has_pdf?(result)
      return show_pdf_title_link(result)
    elsif has_html?(result)
      return show_detail_link(result)
    elsif has_smartlink?(result)
      return show_smartlink_title_link(result)
    elsif has_fulltext?(result)
      return best_customlink(result)
    end
    return ''
  end

  # generate full text link for the detailed record area (not the title link)
  def show_best_fulltext_link_detail(result)
     # raise
    if has_pdf?(result)
      link = '<a href="' + show_pdf_title_link(result) + '">' + pdfIcon + 'PDF Full Text</a>'
    elsif has_html?(result)
      link = '<a href="' + show_best_fulltext_link(result) + '" target="_blank">HTML Full Text</a>'
    elsif has_smartlink?(result)
      link = '<a href="' + show_smartlink_title_link(result) + '">Linked Full Text</a>'
    elsif has_fulltext?(result)
      link = best_customlink_detail(result)
    else
      link = ''
    end
    return link.html_safe
  end

  def has_pdf?(result)
    if result['FullText'].present?
      if result['FullText']['Links'].present?
        result['FullText']['Links'].each do |link|
          if link['Type'] == "pdflink"
            return true
          end
        end
      end
    end
    return false
  end

  def has_html?(result)
    if result['FullText'].present?
      if result['FullText']['Text'].present?
        if result['FullText']['Text']['Availability'].present?
          if result['FullText']['Text']['Availability'].to_s == "1"
            return true
          end
        end
      end
    end
    return false
  end

  def has_fulltext?(result)
    if result['FullText'].present?
      if result['FullText']['CustomLinks'].present?
        result['FullText']['CustomLinks'].each do |customLink|
          if customLink['Category'] == "fullText"
            return true
          end
        end
      end
    end
    return false
  end

  def has_smartlink?(result)
    if result['FullText'].present?
      if result['FullText']['Links'].present?
        result['FullText']['Links'].each do |smartLink|
          if smartLink['Type'] == "other"
            return true
          end
        end
      end
    end
    return false
  end

  def has_ebook?(result)
    if result['FullText'].present?
      if result['FullText']['Links'].present?
        result['FullText']['Links'].each do |smartLink|
          if smartLink['Type'] == "ebook-pdf"
            return true
          elsif smartLink['Type'] == "ebook-epub"
            return true
          end
        end
      end
    end
    return false
  end

  def show_plink(result)
    plink = ''
    if result['PLink'].present?
      plink << result['PLink']
    end
    return plink
  end

  def show_pdf_title_link(result)
    # raise
    title_pdf_link = ''
    if result['Header']['DbId'].present? and result['Header']['An'].present?
      title_pdf_link << request.fullpath.split("?")[0] << "/" << result['Header']['DbId'].to_s << "/" << result['Header']['An'].to_s << "/fulltext"
    end
    new_link = Addressable::URI.unencode(title_pdf_link.to_s)
    return new_link
  end

  def show_smartlink_title_link(result)
    title_pdf_link = ''
    if result['Header']['DbId'].present? and result['Header']['An'].present?
      title_pdf_link << request.fullpath.split("?")[0] << "/" << result['Header']['DbId'].to_s << "/" << result['Header']['An'].to_s << "/fulltext"
    end
    new_link = Addressable::URI.unencode(title_pdf_link.to_s)
    return new_link
  end

  def show_ebook_title_link(result)
    title_pdf_link = ''
    if result['Header']['DbId'].present? and result['Header']['An'].present?
      title_pdf_link << request.fullpath.split("?")[0] << "/" << result['Header']['DbId'].to_s << "/" << result['Header']['An'].to_s << "/fulltext"
    end
    new_link = Addressable::URI.unencode(title_pdf_link.to_s)
    return new_link
  end

  def show_pdf_link(record)
    pdf_link = ''
    if record['FullText'].present?
      if record['FullText']['Links'].present?
        record['FullText']['Links'].each do |link|
          if link['Type'] == "pdflink"
            pdf_link << link['Url']
          end
        end
      end
    end
    return pdf_link
  end

  def show_smartlink(record)
    pdf_link = ''
    if record['FullText'].present?
      if record['FullText']['Links'].present?
        record['FullText']['Links'].each do |link|
          if link['Type'] == "other"
            pdf_link << link['Url']
          end
        end
      end
    end
    return pdf_link
  end

  def show_ebook_link(record)
    pdf_link = ''
    if record['FullText'].present?
      if record['FullText']['Links'].present?
        record['FullText']['Links'].each do |link|
          if link['Type'] == "ebook-pdf"
            pdf_link << link['Url']
          elsif link['Type'] == "ebook-epub"
            pdf_link << link['Url']
          end
        end
      end
    end
    return pdf_link
  end

  def show_fulltext(result)
    fulltext_links = []
    if result['FullText'].present?
      if result['FullText']['CustomLinks'].present?
        result['FullText']['CustomLinks'].each do |customLink|
          if customLink['Category'] == "fullText" and customLink['Text'].present?
            fulltext_links << '<a href="' + customLink['Url'] + '">' + customLink['Text'] + '</a>'
          elsif customLink['Category'] == "fullText"
            fulltext_links << '<a href="' + customLink['Url'] + '">Full Text via CustomLink' + customLink.to_s + '</a> '
          end
        end
      end
    end
    return fulltext_links.join(", ").html_safe
  end

  # show prioritized custom links
  def best_customlink(result)
    fulltext_links = ''
    flag = 0
    if result['FullText'].present?
      if result['FullText']['CustomLinks'].present?
        result['FullText']['CustomLinks'].each do |customLink|
          if customLink['Category'] == "fullText" and flag == 0
            fulltext_links << customLink['Url']
            flag = 1
          end
        end
      end
    end
    return fulltext_links
  end

  def has_elink_link?(result)
    result['CustomLinks'].each do |customLink|
      return true if customLink['Name'] == 'eLink'
    end
    return false
  end

  def show_elink_link(result)
    link_icon = '/assets/elink.gif'
    result['CustomLinks'].each do |customLink|
      next unless customLink['Name'] == 'eLink'

      link = '<a href="' + customLink['Url'] + '" target="_blank"><img src="' + link_icon + '" border="0" class="eds_custom_icon"></a>'
      return link.html_safe
    end
  end

  def best_customlink_detail(result)
# raise
    fulltext_links = ''
    flag = 0
    # return immediately if there's nothing to work with
    return fulltext_links unless result['FullText'].present?
    return fulltext_links unless result['FullText']['CustomLinks'].present?

    result['FullText']['CustomLinks'].each do |customLink|

      # NEXT-1186 - Use the e-link icon instead of the 360 link image
      link360_icon = 'http://images.serialssolutions.com' +
                     '/360link_standard_button.jpg'
      if customLink['Icon'] == link360_icon
        link_icon = '/assets/elink.gif'
      else
        # link_icon = customLink['Icon']
        # # Ebsco's image-server support http or https access.
        # # Switch all image links to https.
        # if link_icon &&
        #    link_icon.start_with?('http://imageserver.ebscohost.com')
        #   link_icon.sub!(/http:/, 'https:')
        # end
        # Don't use any EDS-supplied icons!
        # NEXT-1228 - workshop -- jstor bitmap
        customLink.delete('Icon')
      end

      # Rails.logger.debug "XXXX customLink=#{customLink.inspect}"
      if customLink['Category'] == "fullText" and flag == 0 and customLink['Text'].present? and customLink['Icon'].present?
        fulltext_links << '<a href="' + customLink['Url'] + '" target="_blank"><img src="' + link_icon + '" border="0" class="eds_custom_icon">' + customLink['Text'] + '</a>'
        flag = 1
      elsif customLink['Category'] == "fullText" and flag == 0 and customLink['Text'].present?
        flag = 1
        fulltext_links << '<a href="' + customLink['Url'] + '" target="_blank">' + customLink['Text'] + '</a>'

      # New clauses, per NEXT-1228, for MouseOverText and Name
      elsif customLink['Category'] == "fullText" and flag == 0 and customLink['MouseOverText'].present?
        flag = 1
        fulltext_links << '<a href="' + customLink['Url'] + '" target="_blank">' + customLink['MouseOverText'] + '</a>'
      elsif customLink['Category'] == "fullText" and flag == 0 and customLink['Name'].present?
        flag = 1
        fulltext_links << '<a href="' + customLink['Url'] + '" target="_blank">' + customLink['Name'] + '</a>'

      elsif customLink['Category'] == "fullText" and flag == 0 and customLink['Icon'].present?
        fulltext_links << '<a href="' + customLink['Url'] + '" target="_blank"><img src="' + link_icon + '" border="0" class="eds_custom_icon"></a>'
        flag = 1
      elsif customLink['Category'] == "fullText" and flag == 0
        fulltext_links << '<a href="' + customLink['Url'] + '" target="_blank">Full Text via Custom Link</a>'
        flag = 1
      end
    end

    return fulltext_links
  end

  def has_ill?(result)
      if result['CustomLinks'].present?
        result['CustomLinks'].each do |customLink|
          if customLink['Category'] == "ill"
            return true
          end
        end
      end
    return false
  end

  def show_ill(result)
    fulltext_links = ''
    if result['CustomLinks'].present?
      result['CustomLinks'].each do |customLink|
        if customLink['Category'] == "ill"
          fulltext_links << '<a href="' << customLink['Url'] << '">Request via Interlibrary Loan</a> '
        end
      end
    end
    return fulltext_links.html_safe
  end

# DUPLICATE
  # def has_search_parameters?
  #   !params[:q].blank? or
  #     !params[:f].blank? or
  #     !params[:search_field].blank? or
  #     !params[:eds_action].blank?
  # end

  def has_eds_pointer?
    !params[:eds].blank? or !params[:eds_q].blank?
  end

  def show_sort_and_per_page? response = nil
    response ||= @response
    response.response['numFound'] > 1
  end

  def pdfIcon
    image_tag('/static_icons/pdf.png', size: '20x20', class: 'format_icon')
  end

  ################
  # Columbia local, modeled after other CLIO work
  ###############

  # field_name:   search_field2, search_field3, etc.
  # field_value:  author, title, etc.
  def advanced_eds_field_select_option(field_name, field_value)

    options = DATASOURCES_CONFIG['datasources']['eds']['search_box'] || {}

    field_list = options['search_fields'].map do |field_key, field_label|
      [field_label, field_key]
    end

    select_tag(field_name, options_for_select(field_list, field_value), class: 'form-control')
  end

  ################
  # Debug Functions
  ################

  def show_query_string
    return "nil" unless session[:results] and
                        session[:results]['SearchRequestGet']
                        session[:results]['SearchRequestGet']['QueryString']

    return session[:results]['SearchRequestGet']['QueryString']

    # broken
    # return session[:results]['queryString']
  end

  def debugNotes
    return session[:debugNotes] <<
    "<h4>Returned QueryString</h4>" << show_query_string <<
    "<h4>API Calls</h4>" << @connection.debug_notes
  end

end
