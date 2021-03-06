module radio_page;

import awebview.gui.html;
import awebview.gui.widgets.radio;

import carbon.functional;


class RadioPage : TemplateHTMLPage!(import(`radio_page.html`))
{
    this()
    {
        super("buttonPage", null);
        HTMLRadio[] rs;
        this ~= new InputRadio!()("radio_0").passTo!((a){ rs ~= a; });
        this ~= new InputRadio!()("radio_1").passTo!((a){ rs ~= a; });
        this ~= new InputRadio!()("radio_2").passTo!((a){ rs ~= a; });

        this ~= new HTMLRadioGroup("radio_group", rs);
    }
}
