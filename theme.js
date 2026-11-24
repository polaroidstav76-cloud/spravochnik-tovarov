(()=>{
 const key='cloudshop.appearance.v1',root=document.documentElement;
 let current='light';try{if(localStorage.getItem(key)==='dark')current='dark';}catch{}
 function apply(theme){current=theme==='dark'?'dark':'light';root.dataset.theme=current;root.style.colorScheme=current;
  for(const button of document.querySelectorAll('[data-theme-toggle]')){button.textContent=current==='dark'?'☀ Светлая тема':'☾ Тёмная тема';button.setAttribute('aria-pressed',String(current==='dark'));button.title='Переключить на '+(current==='dark'?'светлую':'тёмную')+' тему';}
 }
 apply(current);
 function mount(container,id){if(!container||document.getElementById(id))return;const button=document.createElement('button');button.type='button';button.id=id;button.className='secondary theme-toggle';button.dataset.themeToggle='';button.onclick=()=>{apply(current==='dark'?'light':'dark');try{localStorage.setItem(key,current);}catch{}};container.append(button);apply(current);}
 // Legacy windows use inline colours. Keep their original light palette and
 // attach dark alternatives without changing business data or photo pixels.
 function rgb(value){if(value==='white')return [255,255,255];if(value==='black')return [0,0,0];const m=/^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/.exec(value);return m&&(!m[4]||Number(m[4])>.9)?m.slice(1,4).map(Number):null;}
 function inlineColours(node){
  if(!(node instanceof HTMLElement)||node.closest('.gr-table'))return;
  for(const [property,attribute,variable] of [['background-color','data-theme-inline-bg','--theme-inline-bg'],['color','data-theme-inline-text','--theme-inline-text']]){
   const colour=rgb(node.style.getPropertyValue(property)),background=property==='background-color';let value=null;
   if(colour){const [r,g,b]=colour,brightness=(r*.2126+g*.7152+b*.0722),span=Math.max(...colour)-Math.min(...colour);
    if(background&&brightness>185){value=span<24?'var(--surface)':r>b+22&&g>b+12?'var(--warn-bg)':g>r+12&&g>b+5?'var(--ok-bg)':r>g+12&&r>b+8?'var(--bad-bg)':'#20344d';}
    if(!background&&brightness<150){value=span<24?'var(--ink)':r>g*1.25&&r>b*1.15?'var(--bad-ink)':g>r*1.2&&g>b?'var(--ok-ink)':r>b*1.3&&g>b?'var(--warn-ink)':'#b2d3ff';}
   }
   if(value){if(node.style.getPropertyValue(variable)!==value)node.style.setProperty(variable,value);if(!node.hasAttribute(attribute))node.setAttribute(attribute,'');}
   else if(node.hasAttribute(attribute)){node.removeAttribute(attribute);node.style.removeProperty(variable);}
  }
 }
 function scan(node){if(!(node instanceof HTMLElement))return;if(node.hasAttribute('style'))inlineColours(node);for(const child of node.querySelectorAll('[style]'))inlineColours(child);}
 function ready(){scan(document.body);new MutationObserver(records=>{for(const r of records){if(r.type==='attributes')inlineColours(r.target);else for(const node of r.addedNodes)scan(node);}}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['style']});mount(document.querySelector('.app-head .top'),'themeToggle');mount(document.querySelector('.desktop-home-actions'),'desktopThemeToggle');mount(document.querySelector('#saleModal .sales-home-head'),'saleThemeToggle');}
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
 window.addEventListener('storage',e=>{if(e.key===key)apply(e.newValue);});
})();
