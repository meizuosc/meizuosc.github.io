$('article.post a').each(function() {
	if (this.hostname != window.location.hostname) {
		this.target = '_blank';
	}});
if (navigator.appVersion.indexOf("Mac") != -1) {
	$('code, pre').css('font-family', 'Courier, monospace');
}

$('article #article_main').each(function(i){
	$(this).find('img').each(function(){
		if ($(this).parent().hasClass('fancybox')) return;

		var alt = this.alt;

		if (alt) $(this).after('<span class="caption">' + alt + '</span>');

		$(this).wrap('<a href="' + this.src + '" title="' + alt + '" class="fancybox"></a>');
	});
	$(this).find('.fancybox').each(function(){
		$(this).attr('rel', 'article' + i);
	});
});

if ($.fancybox){
	$('.fancybox').fancybox();
}
