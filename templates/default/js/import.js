
function google_wait(show_spinner)
{
    if(show_spinner) $('token_working').reveal();

    var req = new Request({ url: api_request_path('webapi', 'token.check', basepath),
                            onSuccess: function(respText, respXML) {
                                var err = respXML.getElementsByTagName("error")[0];
                                if(err) {
                                    $('errboxmsg').set('html', '<p class="error">'+err.getAttribute('info')+'</p>');
                                    errbox.open();

                                // No error, we have a response
                                } else {
                                    var check = respXML.getElementsByTagName("token")[0];

                                    if(check.getAttribute('set') == "true") {
                                        location.reload();
                                    } else {
                                        setTimeout(function() { google_wait(false); }, 1000);
                                    }
                                }
                            }
                          });
    req.post();

    return 1;
}