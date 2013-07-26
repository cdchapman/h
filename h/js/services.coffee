class Hypothesis extends Annotator
  events:
    serviceDiscovery: 'serviceDiscovery'

  # Plugin configuration
  options:
    noMatching: true
    Discovery: {}
    Heatmap: {}
    Permissions:
      permissions:
        read: ['group:__world__']
      userAuthorize: (action, annotation, user) ->
        if annotation.permissions
          tokens = annotation.permissions[action] || []

          if tokens.length == 0
            # Empty or missing tokens array: only admin can perform action.
            return false

          for token in tokens
            if this.userId(user) == token
              return true
            if token == 'group:__world__'
              return true
            if token == 'group:__authenticated__' and this.user?
              return true

          # No tokens matched: action should not be performed.
          return false

        # Coarse-grained authorization
        else if annotation.user
          return user and this.userId(user) == this.userId(annotation.user)

        # No authorization info on annotation: free-for-all!
        true
      showEditPermissionsCheckbox: false,
      showViewPermissionsCheckbox: false,
      userString: (user) -> user.replace(/^acct:(.+)@(.+)$/, '$1 on $2')
    Threading: {}
    Document: {}

  # Internal state
  dragging: false     # * To enable dragging only when we really want to
  ongoing_edit: false # * Is there an interrupted edit by login
  show_search: false  # * Toggle showing the visualsearchbar

  # Here as a noop just to make the Permissions plugin happy
  # XXX: Change me when Annotator stops assuming things about viewers
  viewer:
    addField: (-> )

  this.$inject = ['$document', '$location', '$rootScope', '$route', 'drafts', '$filter']
  constructor: ($document, $location, $rootScope, $route, drafts, $filter) ->
    Gettext.prototype.parse_locale_data annotator_locale_data
    super ($document.find 'body')

    # Load plugins
    for own name, opts of @options
      if not @plugins[name] and name of Annotator.Plugin
        this.addPlugin(name, opts)

    # Set up XDM connection
    this._setupXDM()

    # Add some info to new annotations
    this.subscribe 'beforeAnnotationCreated', (annotation) =>
      # Annotator assumes a valid array of targets and highlights.
      unless annotation.target?
        annotation.target = []
      unless annotation.highlights?
        annotation.highlights = []

      # Register it with the draft service
      drafts.add annotation

    # Set default owner permissions on all annotations
    for event in ['beforeAnnotationCreated', 'beforeAnnotationUpdated']
      this.subscribe event, (annotation) =>
        permissions = @plugins.Permissions
        if permissions.user?
          userId = permissions.options.userId(permissions.user)
          for action, roles of annotation.permissions
            unless userId in roles then roles.push userId

    # Track the visible annotations in the root scope
    $rootScope.annotations = []

    # Add new annotations to the view when they are created
    this.subscribe 'annotationCreated', (a) =>
      unless a.references?
        $rootScope.annotations.unshift a

    # Remove annotations from the application when they are deleted
    this.subscribe 'annotationDeleted', (a) =>
      $rootScope.annotations = $rootScope.annotations.filter (b) -> b isnt a

    # Update the heatmap when the host is updated or annotations are loaded
    bridge = @plugins.Bridge
    heatmap = @plugins.Heatmap
    threading = @threading
    updateOn = [
      'hostUpdated'
      'annotationsLoaded'
      'annotationCreated'
      'annotationDeleted'
    ]
    for event in updateOn
      this.subscribe event, =>
        @provider.call
          method: 'getHighlights'
          success: ({highlights, offset}) ->
            heatmap.updateHeatmap
              highlights:
                for hl in highlights when hl.data
                  annotation = bridge.cache[hl.data]
                  angular.extend hl, data: annotation
              offset: offset

    # Reload the route after annotations are loaded
    this.subscribe 'annotationsLoaded', -> $route.reload()

    @user_filter = $filter('userName')
    search_query = ''
    unless typeof(localStorage) is 'undefined'
      search_query = localStorage.getItem("hyp_page_search_query")
      console.log 'Loading back search query: ' + search_query

    @visualSearch = VS.init
      container: $('.visual-search')
      query: search_query
      callbacks:
        search: (query, searchCollection) =>
          unless query
            return

          matched = []
          whole_document = true
          in_body_text = ''
          for searchItem in searchCollection.models
            if searchItem.attributes.category is 'area' and
            searchItem.attributes.value is 'sidebar'
              whole_document = false

            if searchItem.attributes.category is 'text'
              in_body_text = searchItem.attributes.value.toLowerCase()

          if whole_document
            annotations = @plugins.Store.annotations
          else
            annotations = $rootScope.annotations

          for annotation in annotations
            matches = true
            for searchItem in searchCollection.models
              category = searchItem.attributes.category
              value = searchItem.attributes.value
              switch category
                when 'user'
                  userName = @user_filter annotation.user
                  unless userName.toLowerCase() is value.toLowerCase()
                    matches = false
                    break
                when 'text'
                  unless annotation.text? and annotation.text.toLowerCase().indexOf(value.toLowerCase()) > -1
                    matches = false
                    break
                when 'time'
                    delta = Math.round((+new Date - new Date(annotation.updated)) / 1000)
                    switch value
                      when '5 minutes'
                        unless delta <= 60*5
                          matches = false
                      when '1 hour'
                        unless delta <= 60*60
                          matches = false
                      when '1 day'
                        unless delta <= 60*60*24
                          matches = false
                      when '1 week'
                        unless delta <= 60*60*24*7
                          matches = false
                      when '1 month'
                        unless delta <= 60*60*24*31
                          matches = false
                      when '1 year'
                        unless delta <= 60*60*24*366
                          matches = false
                when 'group'
                    priv_public = 'group:__world__' in (annotation.permissions.read or [])
                    switch value
                      when 'Public'
                        unless priv_public
                          matches = false
                      when 'Private'
                        if priv_public
                          matches = false

            if matches
              matched.push annotation.id

          #Save query to localStorage
          unless typeof(localStorage) is 'undefined'
            try
              localStorage.setItem "hyp_page_search_query", query
            catch error
              console.warn 'Cannot save query to localStorage!'
              if error is QUOTA_EXCEEDED_ERR
                console.warn 'localStorage quota exceeded!'

          # Set the path
          search =
            whole_document : whole_document
            matched : matched
            in_body_text: in_body_text
          $location.path('/page_search').search(search)
          $rootScope.$digest()

        facetMatches: (callback) =>
          if @show_search
            return callback ['text','area', 'group','time','user'], {preserveOrder: true}
        valueMatches: (facet, searchTerm, callback) ->
          switch facet
            when 'group' then callback ['Public', 'Private']
            when 'area' then callback ['sidebar', 'document']
            when 'time'
              callback ['5 minutes', '1 hour', '1 day', '1 week', '1 month', '1 year']
        clearSearch: (original) =>
          @show_search = false
          original()
          $rootScope.$digest()

  _setupXDM: ->
    $location = @element.injector().get '$location'
    $rootScope = @element.injector().get '$rootScope'
    $window = @element.injector().get '$window'
    drafts = @element.injector().get 'drafts'

    # Set up the bridge plugin, which bridges the main annotation methods
    # between the host page and the panel widget.
    whitelist = ['diffHTML', 'quote', 'ranges', 'target', 'id']
    this.addPlugin 'Bridge',
      origin: $location.search().xdm
      window: $window.parent
      formatter: (annotation) =>
        formatted = {}
        for k, v of annotation when k in whitelist
          formatted[k] = v
        formatted
      parser: (annotation) =>
        parsed = {}
        for k, v of annotation when k in whitelist
          parsed[k] = v
        parsed

    @api = Channel.build
      origin: $location.search().xdm
      scope: 'annotator:api'
      window: $window.parent

    .bind('addToken', (ctx, token) =>
      @element.scope().token = token
      @element.scope().$digest()
    )

    @provider = Channel.build
      origin: $location.search().xdm
      scope: 'annotator:panel'
      window: $window.parent
      onReady: => console.log "Sidepanel: channel is ready"

        # Dodge toolbars [DISABLE]
        #@provider.getMaxBottom (max) =>
        #  @element.css('margin-top', "#{max}px")
        #  @element.find('.topbar').css("top", "#{max}px")
        #  @element.find('#gutter').css("margin-top", "#{max}px")
        #  @plugins.Heatmap.BUCKET_THRESHOLD_PAD += max

    @provider

    .bind('publish', (ctx, args...) => this.publish args...)

    .bind('back', =>
      # This guy does stuff when you "back out" of the interface.
      # (Currently triggered by a click on the source page.)
      return unless drafts.discard()
      $rootScope.$apply => this.hide()
    )

  _setupWrapper: ->
    @wrapper = @element.find('#wrapper')
    .on 'mousewheel', (event, delta) ->
      # prevent overscroll from scrolling host frame
      # This is actually a bit tricky. Starting from the event target and
      # working up the DOM tree, find an element which is scrollable
      # and has a scrollHeight larger than its clientHeight.
      # I've obsered that some styles, such as :before content, may increase
      # scrollHeight of non-scrollable elements, and that there a mysterious
      # discrepancy of 1px sometimes occurs that invalidates the equation
      # typically cited for determining when scrolling has reached bottom:
      #   (scrollHeight - scrollTop == clientHeight)
      $current = $(event.target)
      while $current.css('overflow') in ['hidden', 'visible']
        $parent = $current.parent()
        # Break out on document nodes
        if $parent.get(0).nodeType == 9
          event.preventDefault()
          return
        $current = $parent
      scrollTop = $current[0].scrollTop
      scrollEnd = $current[0].scrollHeight - $current[0].clientHeight
      if delta > 0 and scrollTop == 0
        event.preventDefault()
      else if delta < 0 and scrollEnd - scrollTop <= 5
        event.preventDefault()
    this

  _setupDocumentEvents: ->
    el = document.createElementNS 'http://www.w3.org/1999/xhtml', 'canvas'
    el.width = el.height = 1
    @element.append el

    handle = @element.find('.topbar .tri')[0]
    handle.addEventListener 'dragstart', (event) =>
      event.dataTransfer.setData 'text/plain', ''
      event.dataTransfer.setDragImage el, 0, 0
      @dragging = true
      @provider.notify method: 'setDrag', params: true      
      @provider.notify method: 'dragFrame', params: event.screenX
    handle.addEventListener 'dragend', (event) =>
      @dragging = false
      @provider.notify method: 'setDrag', params: false      
      @provider.notify method: 'dragFrame', params: event.screenX
    @element[0].addEventListener 'dragover', (event) =>
      if @dragging then @provider.notify method: 'dragFrame', params: event.screenX
    @element[0].addEventListener 'dragleave', (event) =>
      if @dragging then @provider.notify method: 'dragFrame', params: event.screenX

    this

  # Override things not used in the angular version.
  _setupDynamicStyle: -> this
  _setupViewer: -> this
  _setupEditor: -> this

  # (Optionally) put some HTML formatting around a quote
  getHtmlQuote: (quote) -> quote

  # Do nothing in the app frame, let the host handle it.
  setupAnnotation: (annotation) -> annotation

  showViewer: (annotations=[]) =>
    this.show()
    @element.injector().invoke [
      '$location', '$rootScope',
      ($location, $rootScope) ->
        $rootScope.annotations = annotations
        $location.path('/viewer').replace()
        $rootScope.$digest()
    ]
    this

  clickAdder: =>
    @provider.notify
      method: 'adderClick'

  showEditor: (annotation) =>
    this.show()
    @element.injector().invoke [
      '$location', '$rootScope', '$route'
      ($location, $rootScope, $route) =>
        unless this.plugins.Auth? and this.plugins.Auth.haveValidToken()
          $route.current.locals.$scope.$apply ->
            $route.current.locals.$scope.$emit 'showAuth', true
          @provider.notify method: 'onEditorHide'
          @ongoing_edit = true
          return

        # Set the path
        search =
          id: annotation.id
          action: 'create'
        $location.path('/editor').search(search)

        # Digest the change
        $rootScope.$digest()

        @ongoing_edit = false

        # Push the annotation into the editor scope
        if $route.current.controller is 'EditorController'
          $route.current.locals.$scope.$apply (s) -> s.annotation = annotation
    ]
    this

  show: =>
    @element.scope().frame.visible = true

  hide: =>
    @element.scope().frame.visible = false

  patch_store: (store) =>
    $location = @element.injector().get '$location'
    $rootScope = @element.injector().get '$rootScope'

    # When the store plugin finishes a request, update the annotation
    # using a monkey-patched update function which updates the threading
    # if the annotation has a newly-assigned id and ensures that the id
    # is enumerable.
    store.updateAnnotation = (annotation, data) =>
      if annotation.id? and annotation.id != data.id
        # Update the id table for the threading
        thread = @threading.getContainer annotation.id
        thread.id = data.id
        @threading.idTable[data.id] = thread
        delete @threading.idTable[annotation.id]

        # The id is no longer temporary and should be serialized
        # on future Store requests.
        Object.defineProperty annotation, 'id',
          configurable: true
          enumerable: true
          writable: true

        # If the annotation is loaded in a view, switch the view
        # to reference the new id.
        search = $location.search()
        if search? and search.id == annotation.id
          search.id = data.id
          $location.search(search).replace()

      # Update the annotation with the new data
      annotation = angular.extend annotation, data

      # Give angular a chance to react
      $rootScope.$digest()

  serviceDiscovery: (options) =>
    $location = @element.injector().get '$location'
    $rootScope = @element.injector().get '$rootScope'

    angular.extend @options, Store: options

    # Get the location of the annotated document
    @provider.call
      method: 'getDocumentInfo'
      success: (info) =>
        href = info.uri
        @plugins.Document.metadata = info.metadata

        options = angular.extend {}, (@options.Store or {}),
          annotationData:
            uri: href
          loadFromSearch:
            limit: 1000
            uri: href
        this.addStore(options)

  addStore: (options) ->
    this.addPlugin 'Store', options
    this.patch_store this.plugins.Store

    href = options.loadFromSearch?.uri
    return unless href?

    console.log "Loaded annotions for '" + href + "'."
    for uri in @plugins.Document.uris()
      console.log "Also loading annotations for: " + uri
      this.plugins.Store.loadAnnotationsFromSearch uri: uri


class AuthenticationProvider
  constructor: ->
    @actions =
      load:
        method: 'GET'
        withCredentials: true

    for action in ['login', 'logout', 'register', 'forgot', 'activate']
      @actions[action] =
        method: 'POST'
        params:
          '__formid__': action
        withCredentials: true

    @actions['claim'] = @actions['forgot']

  $get: [
    '$document', '$resource',
    ($document,   $resource) ->
      baseUrl = $document[0].baseURI.replace(/:(\d+)/, '\\:$1')

      # Strip an empty hash and end in exactly one slash
      baseUrl = baseUrl.replace /#$/, ''
      baseUrl = baseUrl.replace /\/*$/, '/'

      $resource(baseUrl, {}, @actions).load()]


class DraftProvider
  drafts: []

  $get: -> this
  add: (draft) -> @drafts.push draft unless this.contains draft
  remove: (draft) -> @drafts = (d for d in @drafts when d isnt draft)
  contains: (draft) -> (@drafts.indexOf draft) != -1

  discard: ->
    count = (d for d in @drafts when d.text?.length).length
    text =
      switch count
        when 0 then null
        when 1
          """You have an unsaved reply.

          Do you really want to discard this draft?"""
        else
          """You have #{count} unsaved replies.

          Do you really want to discard these drafts?"""

    if count == 0 or confirm text
      @drafts = []
      true
    else
      false


class FlashProvider
  queues:
    '': []
    info: []
    error: []
    success: []
  notice: null
  timeout: null

  this.$inject = ['$httpProvider']
  constructor: ($httpProvider) ->
    # Configure notification classes
    angular.extend Annotator.Notification,
      INFO: 'info'
      ERROR: 'error'
      SUCCESS: 'success'

    # Configure the response interceptor
    $httpProvider.responseInterceptors.push ['$q', ($q) =>
      (promise) =>
        promise.then (response) =>
          data = response.data
          format = response.headers 'content-type'
          if format?.match /^application\/json/
            if data.flash?
              this._flash q, msgs for q, msgs of data.flash

            if data.status is 'failure'
              this._flash 'error', data.reason
              $q.reject(data.reason)
            else if data.status is 'okay'
              response.data = data.model
              response
          else
            response
    ]

  _process: ->
    @timeout = null
    for q, msgs of @queues
      if msgs.length
        msg = msgs.shift()
        unless q then [q, msg] = msg
        notice = Annotator.showNotification msg, q
        @timeout = this._wait =>
          # work around Annotator.Notification not removing classes
          for _, klass of notice.options.classes
            notice.element.removeClass klass
          this._process()
        break

  $get: ['$timeout', 'annotator', ($timeout, annotator) ->
    this._wait = (cb) -> $timeout cb, 5000
    angular.bind this, this._flash
  ]

  _flash: (queue, messages) ->
    if @queues[queue]?
      @queues[queue] = @queues[queue]?.concat messages
      this._process() unless @timeout?

angular.module('h.services', ['ngResource','h.filters'])
  .provider('authentication', AuthenticationProvider)
  .provider('drafts', DraftProvider)
  .service('annotator', Hypothesis)
