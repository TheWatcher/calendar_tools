
window.addEvent('domready', function()
{
    if($('notebox'))
        setTimeout(function() { $('notebox').dissolve() }, 8000);

    $$('a.rel').each(function(element) {
                         element.addEvent('click',
                                          function (e) {
                                              e.stop();
                                              window.open(element.href);
                                          });
                     });
});
