/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
var app = {
    // Application Constructor
    initialize: function() {
        this.bindEvents();
    },
    // Bind Event Listeners
    //
    // Bind any events that are required on startup. Common events are:
    // 'load', 'deviceready', 'offline', and 'online'.
    bindEvents: function() {
        document.addEventListener('deviceready', this.onDeviceReady, false);
    },
    // deviceready Event Handler
    //
    // The scope of 'this' is the event. In order to call the 'receivedEvent'
    // function, we must explicity call 'app.receivedEvent(...);'
    onDeviceReady: function() {
        app.receivedEvent('deviceready');
    },
    // Update DOM on a Received Event
    receivedEvent: function(id) {
       // var parentElement = document.getElementById(id);
        //var listeningElement = parentElement.querySelector('.listening');
       // var receivedElement = parentElement.querySelector('.received');

       // listeningElement.setAttribute('style', 'display:none;');
       // receivedElement.setAttribute('style', 'display:block;');

        console.log('Received Event: ' + id);
    }
};

var googleapi = {
authorize: function(options) {
    var deferred = $.Deferred();
    
    //Build the OAuth consent page URL
    var authUrl = 'https://accounts.google.com/o/oauth2/auth?' + $.param({
                                                                         client_id: options.client_id,
                                                                         redirect_uri: options.redirect_uri,
                                                                         response_type: 'code',
                                                                         scope: options.scope
                                                                         });
    
    //Open the OAuth consent page in the InAppBrowser
    var authWindow = window.open(authUrl, '_blank', 'location=no');
    
    //The recommendation is to use the redirect_uri "urn:ietf:wg:oauth:2.0:oob"
    //which sets the authorization code in the browser's title. However, we can't
    //access the title of the InAppBrowser.
    //
    //Instead, we pass a bogus redirect_uri of "http://localhost", which means the
    //authorization code will get set in the url. We can access the url in the
    //loadstart and loadstop events. So if we bind the loadstart event, we can
    //find the authorization code and close the InAppBrowser after the user
    //has granted us access to their data.
    $(authWindow).on('loadstart', function(e) {
                     var url = e.originalEvent.url;
                     var code = /\?code=(.+)$/.exec(url);
                     var error = /\?error=(.+)$/.exec(url);
                     
                     if (code || error) {
                     //Always close the browser when match is found
                     authWindow.close();
                    
                     }
                     
                     if (code) {
                     //Exchange the authorization code for an access token
                     $.post('https://accounts.google.com/o/oauth2/token', {
                            code: code[1],
                            client_id: options.client_id,
                            client_secret: options.client_secret,
                            redirect_uri: options.redirect_uri,
                            grant_type: 'authorization_code'
                            }).done(function(data) {
                                    deferred.resolve(data);
                                    }).fail(function(response) {
                                            deferred.reject(response.responseJSON);
                                            });
                     } else if (error) {
                     //The user denied access to the app
                     deferred.reject({
                                     error: error[1]
                                     });
                     }
                     });
    
    return deferred.promise();
}
};
googleapi.authorize({
                    client_id: '471121443856.apps.googleusercontent.com',
                    client_secret: 'HO8tYtj05BdNd0ZzXbS7Wi8H',
                    redirect_uri: 'http://localhost',
                    scope: 'https://www.googleapis.com/auth/userinfo.profile https://picasaweb.google.com/data/ https://spreadsheets.google.com/feeds'
                    }).done(function(data) {
                            localStorage.Token = data.access_token;
                            localStorage.nameuser=data.name;
                            //$('body').css('background','url(bg_blue.jpg)');
                            //Lungo.Router.article("main", "main-article");
                            
                            }).fail(function(data) {
                                    alert("restart โล้ด");
                                    });